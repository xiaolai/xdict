import Foundation
import Synchronization
import XDictContract
import XDictCore

/// **The core, and what the service keeps beside it**: which files each open dictionary is made of (what admission asks,
/// `Request.refusal(handles:filesOf:)`), and the app's newest token for each file (`TokenLedger`, which every
/// `DescriptorSource` reads). One per service process, shared by every connection: a `DictId` is the process's, not a
/// connection's (ADR-0007 decision 2), so a client that abandons a connection keeps its handles on the next.
final class Dictionaries: Sendable {
    /// Where the core keeps its two kinds of storage (ADR-0009 decision 2).
    struct Storage: Sendable {
        /// `Config.cache_dir`: the indexes, disposable.
        let indexes: URL
        /// `Config.data_dir`: the registry, durable study data (ADR-0002 decision 4), which only this service reads.
        let registry: URL
    }

    private struct State {
        var filesOf: [DictId: [UUID]] = [:]
        var tokens: [UUID: FileToken] = [:]
    }

    private let core: Result<Core, CoreError>
    private let state = Mutex(State())

    init(storage: Storage) {
        core = Result {
            for directory in [storage.indexes, storage.registry] {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    throw CoreError.Io(kind: .other, detail: "cannot create \(directory.lastPathComponent): \(error)")
                }
            }
            var entropy = SystemRandomNumberGenerator()
            let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &entropy) })
            return try Core(config: Config(dataDir: storage.registry.path, cacheDir: storage.indexes.path,
                                           clientProtocol: protocolVersion(), entropy: nonce))
        }.mapError { $0 as? CoreError ?? .Internal(detail: "\($0)") }
    }

    /// What admission reads: the files of every dictionary open here.
    func filesOf() -> [DictId: [UUID]] {
        state.withLock { $0.filesOf }
    }

    /// An admitted request's tokens, merged so an older observation never replaces a newer one (Codex objection 3).
    func observe(_ tokens: [FileToken]) {
        state.withLock { $0.tokens = TokenLedger.merging(tokens, into: $0.tokens) }
    }

    func token(of file: UUID) -> FileToken.State? {
        state.withLock { $0.tokens[file]?.state }
    }

    // MARK: - The operations

    /// Runs an admitted request's operation against the core: its answer and, for an entry or a found resource, the
    /// payload. `files` are the request's handles in the order of its package's files; admission has checked them.
    /// Never throws: every failure is an outcome.
    func run(_ operation: ServiceOperation, files: [FileHandle], progress: (any XDictCore.Progress)?) -> (Outcome, Data?) {
        let core: Core
        switch self.core {
        case .success(let made): core = made
        case .failure(let error): return (.failure(WireError(core: error)), nil)
        }
        do {
            switch operation {
            case .versions:
                return (.answer(.versions(XDictContract.Versions(XDictCore.versions()))), nil)
            case .importPackage(let spec):
                let imported = try core.import(package: try package(spec, files), progress: progress)
                return (.answer(.imported(XDictContract.Imported(imported))), nil)
            case .openPackage(let spec):
                let opened = XDictContract.Opened(try core.open(package: try package(spec, files)))
                if case .ready(let dict, _, _) = opened {
                    state.withLock { $0.filesOf[dict] = spec.files.map(\.id) }
                }
                return (.answer(.opened(opened)), nil)
            case .close(let dict):
                try core.close(dict: dict.rawValue)
                state.withLock { _ = $0.filesOf.removeValue(forKey: dict) }
                return (.answer(.closed), nil)
            case .lookup(let query, let dicts, let options):
                let page = try core.lookup(query: query, dicts: dicts.map(\.rawValue), options: XDictCore.LookupOptions(options))
                return (.answer(.page(XDictContract.Page(page))), nil)
            case .suggest(let prefix, let dicts, let limit):
                return (.answer(.suggestions(try core.suggest(prefix: prefix, dicts: dicts.map(\.rawValue), limit: limit))), nil)
            case .entry(let dict, let entry, let render):
                let (answer, payload) = Answer.of(try core.entry(dict: dict.rawValue, entry: XDictCore.EntryRef(entry),
                                                                 view: XDictCore.View(render)))
                return (.answer(answer), payload)
            case .link(let dict, let url, let origin, let render):
                let link = try core.link(dict: dict.rawValue, url: url, origin: XDictCore.LinkOrigin(origin),
                                         view: XDictCore.View(render))
                return (.answer(.link(XDictContract.Link(link))), nil)
            case .resource(let dict, let path, let render):
                let (answer, payload) = Answer.of(try core.resource(dict: dict.rawValue, path: path, view: XDictCore.View(render)))
                return (.answer(answer), payload)
            // The reader's joins and splits (ADR-0002 decision 3): the core keeps them idempotent, so a retry is safe.
            case .joinLineage(let edition, let lineage):
                let joined = try core.joinLineage(edition: edition.rawValue, lineage: lineage.rawValue)
                return (.answer(.lineage(LineageId(rawValue: joined))), nil)
            case .splitLineage(let edition, let newLineage):
                let split = try core.splitLineage(edition: edition.rawValue, newLineage: newLineage.rawValue)
                return (.answer(.lineage(LineageId(rawValue: split))), nil)
            case .lineageOf(let edition):
                return (.answer(.lineage(try core.lineageOf(edition: edition.rawValue).map(LineageId.init(rawValue:)))), nil)
            // WI-12: every record read once, then kept beside the index; `progress` reports and cancels it.
            case .health(let dict):
                let health = try core.health(dict: dict.rawValue, progress: progress)
                return (.answer(.health(XDictContract.Health(health))), nil)
            // ADR-0010: the service reads the sheets and computes the report; the app only shows it.
            case .readingStyle(let dict):
                return (.answer(.readingStyle(XDictContract.ReadingStyle(try core.readingStyle(dict: dict.rawValue)))), nil)
            // `cancel` is the connection's, never the core's (`ConnectionSession`).
            case .cancel:
                return (.failure(.refused(.unsupportedOperation)), nil)
            }
        } catch let error as CoreError {
            return (.failure(WireError(core: error)), nil)
        } catch {
            return (.failure(.core(.internalFault(detail: "\(error)"))), nil)
        }
    }

    /// The core's package: each file a `DescriptorSource` named as the contract says (an MDX or a volume by its id, a
    /// sidecar by its path in the package), volumes and sidecars in their order. Admission has checked the package's
    /// rules, so an MDX is always there; its absence is reported, never trapped on.
    private func package(_ spec: PackageSpec, _ files: [FileHandle]) throws -> XDictCore.Package {
        var mdx: Location?
        var volumes: [(Int, Location)] = [], sidecars: [(Int, Location)] = []
        for (file, handle) in zip(spec.files, files) {
            let location = Location.source(name: file.name, source: DescriptorSource(
                handle: handle, file: file.id, token: { [weak self] in self?.token(of: $0) }))
            switch file.role {
            case .mdx: mdx = location
            case .mdd: volumes.append((file.order, location))
            case .sidecar: sidecars.append((file.order, location))
            }
        }
        guard let mdx else { throw CoreError.Internal(detail: "an admitted package without an MDX") }
        return XDictCore.Package(mdx: mdx, mdd: volumes.sorted { $0.0 < $1.0 }.map(\.1),
                                 sidecars: sidecars.sorted { $0.0 < $1.0 }.map(\.1))
    }
}

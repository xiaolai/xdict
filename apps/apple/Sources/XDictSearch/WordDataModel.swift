import Foundation
import Observation
import XDictClient
import XDictContract

/// **The word data Settings installs** (plan-word-exploration WI-5): the pack that rhymes, families, roots, forms,
/// synonyms and antonyms read. The app copies the file the reader chose into the app group's container and asks the
/// service to attach it there; the core validates it with the loader the exploration modes use, so a damaged file or
/// one of another version is refused as a kind (the app words it, ADR-0007 decision 10) and the pack already
/// installed stays.
///
/// **The file on disk is the record, the service's answer is the truth**: at launch the app attaches what the
/// container holds, because the service starts with nothing attached; the state shown is always what the service last
/// answered, never what the app assumes from the disk.
@MainActor
@Observable
public final class WordDataModel {
    /// What the row says.
    public enum State: Equatable, Sendable {
        /// Nobody has asked the service yet.
        case unknown
        /// The service holds no pack: the modes that need one say what they need.
        case absent
        /// The pack installed, as the core reports it.
        case installed(WordPackInfo)
        /// A file was refused, by the kind the core refused it with (`WordDataRefusal`): the app words it.
        case refused(WordDataRefusal)
        /// The container could not be reached, a file could not be copied, or the call failed without a core refusal:
        /// the app's own trouble, never a claim about the pack's contents.
        case trouble(WordDataTrouble)
    }

    public private(set) var state: State = .unknown
    /// A copy or an attach is running: the row's buttons are disabled meanwhile.
    public private(set) var busy = false

    @ObservationIgnored private let backend: any SearchBackend
    @ObservationIgnored private let container: @Sendable () -> URL?
    @ObservationIgnored private var generation = 0

    /// `container` names the app group's `WordPack` folder, or nil in a process without the entitlement (the test
    /// hosts). The model never falls back to another folder: a pack the service cannot read is no pack.
    public init(backend: any SearchBackend, container: @escaping @Sendable () -> URL?) {
        self.backend = backend
        self.container = container
    }

    /// The installed pack's path in the container, when there is one and the file exists.
    public var installedFile: URL? {
        guard let folder = container() else { return nil }
        let file = folder.appending(path: AppGroup.wordPackFile)
        return FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) ? file : nil
    }

    /// **What launch does**: asks the service what it holds, and attaches the container's file only when the service
    /// holds none — after a service restart, or a first launch. **The question comes first** because attaching means
    /// parsing 183 MB: a Settings pane opened on a Mac that already has the pack costs one short call, not that parse.
    public func restore() async {
        await refresh()
        if case .absent = state, let file = installedFile {
            await attach(path: file)
        }
    }

    public func refresh() async {
        await ask(.wordPack)
    }

    /// **Installs `url`**, a file the reader chose: copied into the container under the one name the service is told,
    /// then attached. A refusal deletes the copy, so the container never holds a pack the service rejected.
    public func install(_ url: URL) async {
        guard let folder = container() else {
            state = .trouble(.noContainer)
            return
        }
        busy = true
        defer { busy = false }
        let staged = folder.appending(path: AppGroup.wordPackFile + ".incoming")
        let destination = folder.appending(path: AppGroup.wordPackFile)
        // **The copy runs off the main actor**: it is up to 183 MB from a volume the reader chose, and the window must
        // stay live while it happens. Nothing is replaced yet: a file that is later refused leaves the installed pack
        // exactly where it was.
        let copied = await Task.detached { () -> Bool in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.copyItem(at: url, to: staged)
                return true
            } catch {
                return false
            }
        }.value
        guard copied else {
            state = .trouble(.copyFailed)
            return
        }
        // The staged file is attached first; only an accepted pack replaces the installed one.
        let accepted = await attach(path: staged)
        guard accepted else {
            try? FileManager.default.removeItem(at: staged)
            return
        }
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } catch {
            // The pack is attached and the staged copy is the file on disk under another name: keep it rather than
            // report an install that is not there.
            try? FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    /// **Removes the pack**: the service detaches it, then the app deletes the file. A failed detach keeps the file, so
    /// what the row says and what the container holds stay the same.
    public func remove() async {
        busy = true
        defer { busy = false }
        let folder = container()
        let file = folder?.appending(path: AppGroup.wordPackFile)
        let outcome = await backend.request(.clearWordPack)
        guard case .success = outcome else {
            state = .trouble(.removeFailed)
            return
        }
        if let file { try? FileManager.default.removeItem(at: file) }
        state = .absent
    }

    @discardableResult private func attach(path: URL) async -> Bool {
        busy = true
        defer { busy = false }
        generation += 1
        let mine = generation
        let outcome = await backend.request(.setWordPack(path: path.path(percentEncoded: false)))
        guard mine == generation else { return false }
        switch outcome.wordPack {
        case .success(let state):
            self.state = state.pack.map { .installed($0) } ?? .absent
            return true
        case .failure(.wire(let error)):
            state = .refused(WordDataRefusal(error))
            return false
        case .failure:
            state = .trouble(.noAnswer)
            return false
        }
    }

    private func ask(_ operation: ServiceOperation) async {
        generation += 1
        let mine = generation
        let outcome = await backend.request(operation)
        guard mine == generation else { return }
        switch outcome.wordPack {
        case .success(let state): self.state = state.pack.map { .installed($0) } ?? .absent
        case .failure(.wire(let error)): state = .refused(WordDataRefusal(error))
        case .failure: state = .trouble(.noAnswer)
        }
    }
}

/// **Why a pack was refused, as a kind** (ADR-0007 decision 10: the service sends kinds, the app words them). A version
/// refusal keeps the version the file declares, which is the one thing the reader has to act on.
public enum WordDataRefusal: Equatable, Sendable {
    /// The file's schema version is not the one this XDict reads.
    case version(found: String)
    /// The loader refused the file as damaged, cut short, or not a pack.
    case damaged
    /// Past a size or a record count this XDict holds.
    case tooLarge
    /// The file could not be read at all.
    case unreadable
    /// The call failed before the core saw a file: no answer, or the transport's refusal.
    case transport

    public init(_ error: WireError) {
        switch error {
        case .core(.unsupported(.formatVersion(let version), _)): self = .version(found: version)
        case .core(.malformed): self = .damaged
        case .core(.tooLarge): self = .tooLarge
        case .core(.io): self = .unreadable
        default: self = .transport
        }
    }
}

/// **What went wrong around the pack, without the core refusing it**: no container to put it in, a copy that failed, a
/// removal the service did not confirm, or no answer at all. Each has its own sentence, since each is a different thing
/// for the reader to do.
public enum WordDataTrouble: Equatable, Sendable {
    /// The app group's container is unreachable: no entitlement, or a process that has none (the test hosts).
    case noContainer
    /// The chosen file could not be copied into the container.
    case copyFailed
    /// The service did not confirm the removal; the file is kept, so the row still tells the truth.
    case removeFailed
    /// The service sent no answer.
    case noAnswer
}

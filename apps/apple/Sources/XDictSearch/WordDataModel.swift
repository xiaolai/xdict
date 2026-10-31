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
        /// The pinned files are arriving (plan-local-word-pack WI-6): which one, of how many, and the bytes of all.
        case downloading(WordDataProgress)
        /// Every source is here and the service is building the pack (contract 20): the bytes of the sources it has
        /// parsed so far, of all to parse — zero until it parses the first one, after checking them all.
        case building(WordDataBuild)
        /// The pack installed, as the core reports it.
        case installed(WordPackInfo)
        /// A file was refused, by the kind the core refused it with (`WordDataRefusal`): the app words it.
        case refused(WordDataRefusal)
        /// The container could not be reached, a file could not be copied, or the call failed without a core refusal:
        /// the app's own trouble, never a claim about the pack's contents.
        case trouble(WordDataTrouble)
    }

    public private(set) var state: State = .unknown
    /// A copy, a download or an attach is running: the row's buttons are disabled meanwhile.
    public private(set) var busy = false
    /// **A download and build are running**, observable in its own right: the row draws a Cancel button from it, and a
    /// flag hidden behind an `@ObservationIgnored` task handle never redrew the row when the work ended.
    public private(set) var isWorking = false
    /// The download and build started by `buildFromSources`, held so the row can stop it.
    @ObservationIgnored private var working: Task<Void, Never>?

    @ObservationIgnored private let backend: any SearchBackend
    @ObservationIgnored private let container: @Sendable () -> URL?
    /// The manifest that ships in the app: the bytes the download checks each file against. `nil` is the trouble the
    /// row reports, never a list compiled into the shell.
    @ObservationIgnored private let manifest: @Sendable () -> Data?
    /// The network the sources arrive over: `URLSession` in the app, a fake in the tests.
    @ObservationIgnored private let transfer: any WordPackTransfer
    @ObservationIgnored private var generation = 0

    /// `container` names the app group's `WordPack` folder, or nil in a process without the entitlement (the test
    /// hosts). The model never falls back to another folder: a pack the service cannot read is no pack.
    public init(backend: any SearchBackend, container: @escaping @Sendable () -> URL?,
                manifest: @escaping @Sendable () -> Data? = WordDataModel.bundledManifest,
                transfer: any WordPackTransfer = URLSessionTransfer()) {
        self.backend = backend
        self.container = container
        self.manifest = manifest
        self.transfer = transfer
    }

    /// **What the row is doing now**, as a kind the view layer words; nil when nothing is under way. A phase is named
    /// while work runs, so the reader is never left without evidence that something is happening.
    public var phase: WordDataPhase? {
        switch state {
        case .downloading: .downloading
        case .building(let progress): progress.phase
        case .unknown, .absent, .installed, .refused, .trouble: nil
        }
    }

    /// **How far the phase has got, from 0 to 1**, or nil where the amount is not known yet: the row draws a moving
    /// bar then, never a bar at zero while work goes on.
    public var fraction: Double? {
        switch state {
        case .downloading(let progress): progress.fraction
        case .building(let progress): progress.fraction
        case .unknown, .absent, .installed, .refused, .trouble: nil
        }
    }

    /// The manifest in the app's own bundle, checked against `Resources/WordPack.sha256` when that file is there: a
    /// bundle whose manifest was damaged is no manifest at all.
    nonisolated public static func bundledManifest() -> Data? {
        guard let url = Bundle.main.url(forResource: "WordPackSources", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        guard let pin = Bundle.main.url(forResource: "WordPack", withExtension: "sha256"),
              let pinned = try? String(contentsOf: pin, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !pinned.isEmpty
        else { return data }
        let found = WordPackDownload.measure(of: data)
        return found == pinned ? data : nil
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

    /// **Builds the pack on this Mac from the pinned sources** (plan-local-word-pack WI-6): the app downloads each file
    /// into the container, checks it against the manifest that ships in the app, and asks the service to build it —
    /// which writes the pack and installs what it wrote. The network is the app's, never the service's (ADR-0003).
    ///
    /// A download that fails names its file and leaves nothing behind; a cancel removes what it wrote and installs
    /// nothing; a build the service refuses comes back as a refusal with the builder's own sentence.
    public func buildFromSources() async {
        guard container() != nil else {
            state = .trouble(.noContainer)
            return
        }
        guard let manifest = manifest(), let sources = WordPackSources(manifest) else {
            state = .trouble(.noManifest)
            return
        }
        let work = Task { await self.run(sources, manifest) }
        working = work
        isWorking = true
        await work.value
        working = nil
        isWorking = false
    }

    /// **Stops a running build**: the download stops, what it wrote is removed, and nothing is installed.
    public func cancelBuild() {
        working?.cancel()
    }

    private func run(_ sources: WordPackSources, _ manifest: Data) async {
        guard let folder = container() else {
            state = .trouble(.noContainer)
            return
        }
        busy = true
        defer { busy = false }
        let sourceFolder = folder.appending(path: "sources")
        do {
            try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
            try manifest.write(to: sourceFolder.appending(path: WordPackSources.manifestName), options: .atomic)
            state = .downloading(WordDataProgress(file: 1, files: sources.items.count,
                                                  name: sources.items.first?.file ?? "", done: 0,
                                                  total: sources.totalBytes))
            let download = WordPackDownload(sources: sources, transfer: transfer)
            try await download.fetch(into: sourceFolder) { [weak self] file, done, total in
                Task { @MainActor in
                    // **Only while the download is the phase**: a report that lands after the build started, or after a
                    // cancel, would put `downloading` back over a state the reader has already been told.
                    guard let self, case .downloading = self.state else { return }
                    let name = sources.items.indices.contains(file - 1) ? sources.items[file - 1].file : ""
                    self.state = .downloading(WordDataProgress(file: file, files: sources.items.count, name: name,
                                                               done: done, total: total))
                }
            }
        } catch is CancellationError {
            state = .absent
            return
        } catch let failure as WordPackDownload.Failure {
            state = .trouble(.download(failure))
            return
        } catch {
            state = .trouble(.copyFailed)
            return
        }
        // **A cancel that arrived during the download starts no build**: the service call is not interruptible from
        // here (`SearchBackend` exposes no ticket for a long call), so not starting it is what can be honoured.
        if Task.isCancelled {
            state = .absent
            return
        }
        state = .building(WordDataBuild())
        let output = folder.appending(path: AppGroup.wordPackFile)
        let request = ServiceOperation.buildWordPack(
            sources: sourceFolder.path(percentEncoded: false),
            manifest: sourceFolder.appending(path: WordPackSources.manifestName).path(percentEncoded: false),
            output: output.path(percentEncoded: false))
        // **The core's own progress, heard while it builds** (contract 20): the bytes of the sources it has parsed, of
        // all to parse. Its first reports are zero while it checks the sources it was handed, and the row says that in
        // words rather than drawing a bar that would look stuck.
        let outcome = await backend.request(request) { [weak self] done, total in
            Task { @MainActor in
                guard let self, case .building = self.state else { return }
                self.state = .building(WordDataBuild(done: done, total: total))
            }
        }
        switch outcome.wordPackBuilt {
        case .success(let answer):
            state = answer.pack.map { .installed($0) } ?? .absent
        // **The builder's own sentence survives**: it names the source and the line, which is the one thing a reader
        // with a damaged download needs; flattening it into "damaged file" throws that away.
        case .failure(.wire(.core(.malformed(let detail)))), .failure(.wire(.core(.unsupported(_, let detail)))),
             .failure(.wire(.core(.tooLarge(_, let detail)))), .failure(.wire(.core(.io(_, let detail)))):
            state = .refused(.build(detail: detail))
        case .failure(.wire(let error)):
            state = .refused(WordDataRefusal(error))
        case .failure:
            state = .trouble(.noAnswer)
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
        // **A file that would not go is said, not swallowed** (audit, 2026-10-28): the pack is detached, but the file
        // is what the next launch attaches, so reporting `absent` over a surviving file would make Remove a lie.
        if let file {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                state = .trouble(.removeFailed)
                return
            }
        }
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
    /// **The builder refused the sources**, with the sentence it wrote: a source missing, one whose hash does not
    /// match, one that does not parse (the sentence names its line), or a pack past a bound.
    case build(detail: String)

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
    /// The app's bundle holds no word-data manifest this release reads, or one that fails its own pin.
    case noManifest
    /// A pinned file did not arrive, arrived at the wrong size, or was not the file the manifest pins.
    case download(WordPackDownload.Failure)
}

/// **How far the download has got** (plan-local-word-pack WI-6): the file being fetched, of how many, and the bytes
/// done of all — what the row's bar counts and its sentence names.
public struct WordDataProgress: Equatable, Sendable {
    /// The file being fetched, 1-based.
    public let file: Int
    /// How many files there are.
    public let files: Int
    /// The name of the file being fetched, as the manifest writes it.
    public let name: String
    /// Bytes finished.
    public let done: UInt64
    /// Bytes there are to finish.
    public let total: UInt64

    public init(file: Int, files: Int, name: String = "", done: UInt64, total: UInt64) {
        self.file = file
        self.files = files
        self.name = name
        self.done = done
        self.total = total
    }

    /// **How much of the download is done, from 0 to 1; nil before the first byte**, so the row draws a moving bar
    /// rather than a bar at zero while the first file is on its way.
    public var fraction: Double? {
        guard total > 0, done > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }
}

/// **What the Word data row is doing**, as a kind the view layer words: the phases of getting the pack onto this Mac.
public enum WordDataPhase: Equatable, Sendable {
    /// The pinned files are arriving; the row names the file and its bytes.
    case downloading
    /// No source byte is parsed yet: the service is checking the sources it was handed, or parsing the first one.
    case preparing
    /// The core is parsing the sources; the row counts the bytes parsed.
    case building
    /// Every source is parsed and the pack is being written.
    case writing
}

/// **How far the core's build has got** (contract 20): the bytes of the sources it has parsed, of all to parse. A
/// report of zero means it has parsed nothing yet — the sources are still being checked — and a report of all means
/// the parsing is done and the pack is being written; the row words both rather than drawing a frozen bar.
public struct WordDataBuild: Equatable, Sendable {
    /// Bytes parsed.
    public let done: UInt64
    /// Bytes there are to parse.
    public let total: UInt64

    public init(done: UInt64 = 0, total: UInt64 = 0) {
        self.done = done
        self.total = total
    }

    /// The phase the report names.
    public var phase: WordDataPhase {
        guard total > 0, done > 0 else { return .preparing }
        return done >= total ? .writing : .building
    }

    /// **The bar's value, from 0 to 1, while the sources are being parsed**; nil for the preparing and writing phases,
    /// whose amount the core does not report yet — the row says what it is doing in words there.
    public var fraction: Double? {
        guard phase == .building else { return nil }
        return min(1, Double(done) / Double(total))
    }
}

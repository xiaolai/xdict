import Foundation
import Observation
import XDictAppleSource
import XDictClient
import XDictContract
import os

/// Where one dictionary is, this session (never stored: a relaunch asks again).
public enum EntryPhase: Hashable, Sendable {
    /// Queued for import.
    case waiting
    /// Being imported: bytes read of all the package's files, as the service reports them.
    case importing(done: UInt64, total: UInt64)
    case cancelling
    case opening
    /// Open, and answering lookups.
    case ready
    /// The reader stopped its import; a retry is offered.
    case cancelled
    /// The file itself cannot be read, for a named reason (kept with the dictionary).
    case refused(ImportRefusal)
    /// Something passing failed; a retry is offered.
    case failed(ImportRefusal)
    /// A file of it is not where it was, and its bookmark finds it nowhere.
    case missing(fileName: String)
    /// A file of it is now a link, or has left the folder the reader chose: never read (ADR-0009 refutation row 7).
    case outsideItsFolder(fileName: String)
}

/// Where one dictionary's health check is (WI-12), this session: the core keeps the report per edition, so a relaunch
/// asks again and is answered at once.
public enum HealthState: Hashable, Sendable {
    /// Records checked of all.
    case checking(done: UInt64, total: UInt64)
    case checked(Health)
    /// The check could not finish (the service failed, or the file changed); asked again at the next open.
    case unavailable
}

/// Where one dictionary's reading-style report is (ADR-0010), this session: asked when its details are shown.
public enum StyleState: Hashable, Sendable {
    case reading
    case read(ReadingStyle)
    /// The service could not answer; asked again when the details are next shown.
    case unavailable
}

/// Something the reader should be told once, not kept with any dictionary.
public enum LibraryNotice: Hashable, Sendable {
    case finder(FinderProblem)
    /// What was added is already in the library, under this name.
    case alreadyInLibrary(name: String)
    /// What was added is the edition of a dictionary whose files were missing: that dictionary was found again.
    case relinked(name: String)
    /// What was added is locked to its buyer with a registration code, so it was not added (ADR-0005 decision 4).
    case locked(fileName: String)
    /// The library could not be written.
    case notSaved(LibraryStoreError)
}

extension LibraryEntry {
    /// The name the reader sees (`DisplayName`).
    public var displayName: String {
        DisplayName.of(readers: readersName, title: info?.title ?? "", fileName: mdx?.fileName ?? "")
    }
}

/// **The reader's library** (plan-macos-v1 WI-5; ADR-0009 decision 2): the dictionaries, in the reader's order, each
/// with its files (a bookmark and a file id apiece), its edition and lineage, its name, languages and enablement; their
/// imports — one at a time, with progress, cancel and retry, while every dictionary already open goes on answering
/// (L4); each open handle for the session. Kept in `LibraryStore` after every change; a library that cannot be read is
/// never written over.
///
/// - **Moved files** are found by their bookmarks at every open (L5); with `Options.relinking` off, only where they
///   were (the E2E positive control). A dictionary whose bookmark finds nothing is relinked when the reader adds a file
///   of the same edition.
/// - **A changed edition** (`open` answering `needsImport(changed)`) is imported again, and becomes a new edition with
///   a lineage of its own; the reader is asked (`LibraryEntry.offer`), and only `acceptJoin` joins it to the lineage it
///   had (`joinLineage`), which `undoJoin` undoes exactly (`splitLineage` to the lineage the import gave it; ADR-0002
///   decision 3, as amended 2026-10-14).
@MainActor
@Observable
public final class Library {
    public struct Options: Sendable {
        /// Bookmarks are asked for where a file is now; off, only the path it was last found at.
        public var relinking: Bool

        public init(relinking: Bool = true) {
            self.relinking = relinking
        }
    }

    public private(set) var entries: [LibraryEntry] = []
    public private(set) var phases: [UUID: EntryPhase] = [:]
    public private(set) var notices: [LibraryNotice] = []
    /// Each open dictionary's health check (WI-12), run one at a time after it opens, below the reader's own calls.
    public private(set) var health: [UUID: HealthState] = [:]
    /// Each open dictionary's reading-style report (ADR-0010), asked by its details pane and kept this session.
    public private(set) var readingStyles: [UUID: StyleState] = [:]
    /// Why the stored library could not be read: until it can, nothing is added and nothing is saved.
    public private(set) var unreadable: LibraryStoreError?
    /// Each Apple dictionary's edition and lineage, kept past its removal (`AppleLineage`, ADR-0011 decision 8).
    public private(set) var appleLineages: [String: AppleLineage] = [:]
    /// What became of each Apple dictionary's installed bundle, as last compared (`setAppleStatus`).
    public private(set) var appleStatus: [UUID: AppleStatus] = [:]

    /// Every change of phase, for the instruments: who measured what, when.
    @ObservationIgnored public var onPhase: (@MainActor (UUID, EntryPhase) -> Void)?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let backend: any LibraryBackend
    @ObservationIgnored private let locator: FileLocator
    @ObservationIgnored private let log = Logger(subsystem: "ai.xdict.app", category: "library")
    /// Each open dictionary's handle, this session.
    @ObservationIgnored private var handles: [UUID: DictId] = [:]
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var running: Running?
    @ObservationIgnored private var busy = 0
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Dictionaries waiting for their health check, and the one being checked.
    @ObservationIgnored private var checks: [UUID] = []
    @ObservationIgnored private var checking: (id: UUID, dict: DictId, job: HealthJob?)?
    /// Apple dictionaries the reader asked to Convert Again: the new edition their import makes is joined to the
    /// dictionary's lineage, as one recorded join the reader can undo (ADR-0011 decision 8).
    @ObservationIgnored private var convertingAgain: Set<UUID> = []

    /// The import under way: its entry, and the service's job once it has one.
    private final class Running {
        let id: UUID
        var job: ImportJob?
        var cancelled = false

        init(id: UUID) {
            self.id = id
        }
    }

    public init(store: LibraryStore, backend: any LibraryBackend, options: Options = Options()) {
        self.store = store
        self.backend = backend
        locator = FileLocator(relinking: options.relinking)
    }

    /// The handles of every enabled dictionary that is open, in the reader's order: what a lookup asks.
    public var answering: [DictId] {
        entries.filter { $0.enabled && phases[$0.id] == .ready }.compactMap { handles[$0.id] }
    }

    /// The handle of one dictionary, if it is open.
    public func handle(_ id: UUID) -> DictId? {
        phases[id] == .ready ? handles[id] : nil
    }

    // MARK: - Launch

    /// Reads the library and opens every dictionary in it: one whose file changed or whose index is gone is imported
    /// again, one never imported is imported, one refused stays refused until the reader retries it.
    public func start() async {
        busy += 1
        defer { busy -= 1; wake() }
        do {
            let document = try store.load()
            entries = document?.entries ?? []
            appleLineages = document?.appleLineages ?? [:]
        } catch {
            unreadable = error
            log.error("the library could not be read (\(String(describing: error), privacy: .public)); it is left as it is")
            return
        }
        for entry in entries {
            if Self.isLockedAtImport(entry) {
                dropLocked(entry.id)
            } else if let refusal = entry.refusal {
                set(entry.id, .refused(refusal))
            } else if entry.edition == nil {
                enqueue(entry.id)
            } else {
                await open(entry.id)
            }
        }
    }

    /// Opens every dictionary again, as at launch: how a file rewritten under the library is noticed.
    public func refresh() async {
        busy += 1
        defer { busy -= 1; wake() }
        for entry in entries where entry.refusal == nil && entry.edition != nil && running?.id != entry.id
            && !queue.contains(entry.id) {
            await open(entry.id)
        }
    }

    /// Whether nothing is queued, importing or opening by the time `limit` has passed: true as soon as that is so, false
    /// at the limit. Bounded, so that an import that never ends is a failed check rather than a wait without end.
    public func settled(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        let alarm = Task { [weak self] in
            guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
            self?.wakeEveryWaiter()
        }
        defer { alarm.cancel() }
        while running != nil || !queue.isEmpty || busy > 0 {
            guard ContinuousClock.now < deadline else { return false }
            await withCheckedContinuation { waiters.append($0) }
        }
        return true
    }

    private func wake() {
        guard running == nil, queue.isEmpty, busy == 0 else { return }
        wakeEveryWaiter()
    }

    private func wakeEveryWaiter() {
        let ready = waiters
        waiters = []
        for waiter in ready { waiter.resume() }
    }

    // MARK: - Adding

    /// Adds what the reader chose — files, folders, or both (`PackageFinder`) — and queues each new dictionary's
    /// import. What gives no dictionary, or is already here, is said in `notices`. Answers the new entries' ids.
    @discardableResult
    public func add(_ urls: [URL]) -> [UUID] {
        guard unreadable == nil else { return [] }
        let found = PackageFinder.find(in: urls)
        notices += found.problems.map(LibraryNotice.finder)
        var added: [UUID] = []
        for package in found.packages {
            if let existing = entries.first(where: { $0.mdx?.location.path == package.mdx.path }) {
                notices.append(.alreadyInLibrary(name: existing.displayName))
                continue
            }
            do {
                let entry = try Self.entry(for: package)
                entries.append(entry)
                added.append(entry.id)
            } catch {
                notices.append(.finder(.unreadable(fileName: package.mdx.lastPathComponent)))
            }
        }
        save()
        for id in added { enqueue(id) }
        return added
    }

    static func entry(for package: FoundPackage) throws -> LibraryEntry {
        var files = [StoredFile(id: UUID(), role: .mdx, order: 0, pathInPackage: nil,
                                fileName: package.mdx.lastPathComponent, location: try FileLocator.store(package.mdx))]
        for (order, volume) in package.volumes.enumerated() {
            files.append(StoredFile(id: UUID(), role: .mdd, order: order, pathInPackage: nil, fileName: volume.fileName,
                                    location: try FileLocator.store(volume.url)))
        }
        for (order, sidecar) in package.sidecars.enumerated() {
            files.append(StoredFile(id: UUID(), role: .sidecar, order: order, pathInPackage: sidecar.pathInPackage,
                                    fileName: sidecar.pathInPackage, location: try FileLocator.store(sidecar.url)))
        }
        var entry = LibraryEntry(id: UUID(), root: try FileLocator.store(package.root), files: files,
                                 languages: Languages(proposal: LanguageProposal.from(fileName: package.mdx.lastPathComponent)))
        entry.notes = package.notes
        return entry
    }

    // MARK: - Importing

    private func enqueue(_ id: UUID) {
        guard running?.id != id, !queue.contains(id) else { return }
        queue.append(id)
        set(id, .waiting)
        pump()
    }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return wake() }
        let id = queue.removeFirst()
        let current = Running(id: id)
        running = current
        Task { await self.runImport(current) }
    }

    private func runImport(_ current: Running) async {
        defer {
            running = nil
            pump()
        }
        let id = current.id
        guard index(id) != nil else { return }
        let package: DictionaryPackage
        switch resolve(id) {
        case .success(let resolved): package = resolved
        case .failure(let unresolved): return set(id, unresolved.phase)
        }
        set(id, .importing(done: 0, total: 0))
        let job = await backend.beginImport(package) { [weak self] done, total in
            Task { @MainActor in self?.progressed(id, done: done, total: total) }
        }
        current.job = job
        if current.cancelled { await job.cancel() }
        let outcome = await job.outcome()
        switch outcome {
        case .success(let imported):
            let again = convertingAgain.remove(id) != nil
            // Opened while the import still holds its turn, so `settled` waits for the dictionary to answer.
            if let opening = recordImport(id, imported) {
                // Convert Again said what it does: the new edition joins this dictionary, recorded and undoable.
                if again, entries.first(where: { $0.id == opening })?.offer != nil { _ = await acceptJoin(opening) }
                await open(opening, package: package)
            }
        case .failure(let failure):
            convertingAgain.remove(id)
            let refusal = ImportRefusal(failure, fileName: { [entries] file in
                entries.lazy.flatMap(\.files).first { $0.id == file }?.fileName
            })
            fail(id, refusal)
        }
    }

    private func progressed(_ id: UUID, done: UInt64, total: UInt64) {
        guard running?.id == id, running?.cancelled == false, case .importing = phases[id] else { return }
        set(id, .importing(done: done, total: total))
    }

    private func fail(_ id: UUID, _ refusal: ImportRefusal) {
        guard let at = index(id) else { return }
        if refusal == .cancelled {
            set(id, .cancelled)
        } else if refusal == .registrationCode, entries[at].edition == nil {
            dropLocked(id)
        } else if refusal.isPermanent {
            entries[at].refusal = refusal
            save()
            set(id, .refused(refusal))
        } else if case .missingFile(let name) = refusal {
            set(id, .missing(fileName: name))
        } else {
            set(id, .failed(refusal))
        }
    }

    /// A file locked with a registration code that never opened: XDict does not take it at all (owner, 2026-10-17;
    /// ADR-0005 decision 4). One that once opened has an edition and a lineage the reader's settings are kept under
    /// (ADR-0002), so it stays, refused, until the reader removes it.
    private static func isLockedAtImport(_ entry: LibraryEntry) -> Bool {
        entry.refusal == .registrationCode && entry.edition == nil
    }

    /// Takes a locked file out of the library, and says so once.
    private func dropLocked(_ id: UUID) {
        guard let at = index(id) else { return }
        let name = entries[at].mdx?.fileName ?? entries[at].displayName
        forget(id)
        save()
        notices.append(.locked(fileName: name))
    }

    /// A finished import: its edition, lineage, header and problems — or, when its edition is already in the library,
    /// the dictionary that edition belongs to, relinked if its files were missing. Answers the dictionary to open.
    private func recordImport(_ id: UUID, _ imported: Imported) -> UUID? {
        guard let at = index(id) else { return nil }
        if let other = entries.firstIndex(where: { $0.id != id && $0.edition == imported.edition }) {
            let otherID = entries[other].id
            let name = entries[other].displayName
            defer { save() }
            switch phases[otherID] {
            case .missing, .outsideItsFolder, .failed, .cancelled, .none:
                entries[other].files = entries[at].files
                entries[other].root = entries[at].root
                entries[other].notes = notes(entries[at].notes, imported.problems, files: entries[at].files)
                entries[other].refusal = nil
                entries[other].info = imported.info
                notices.append(.relinked(name: name))
                forget(id)
                return otherID
            default:
                notices.append(.alreadyInLibrary(name: name))
                forget(id)
                return nil
            }
        }
        var entry = entries[at]
        if let earlierEdition = entry.edition, earlierEdition != imported.edition, let earlierLineage = entry.lineage,
           earlierLineage != imported.lineage {
            // A question already open keeps the dictionary's earlier lineage: the reader has not answered it yet.
            let earlier = entry.offer.map { ($0.earlierEdition, $0.earlierLineage) } ?? (earlierEdition, earlierLineage)
            entry.offer = JoinOffer(edition: imported.edition, mintedLineage: imported.lineage,
                                    earlierEdition: earlier.0, earlierLineage: earlier.1)
            entry.join = nil
        } else if entry.edition == nil, entry.offer == nil, let source = entry.appleSource,
                  let earlier = appleLineages[source.bundleIdentifier], earlier.lineage != imported.lineage {
            // A fresh import of an Apple dictionary the reader once had (removed, or split from its lineage): a new
            // lineage, with the join to the earlier one suggested, never applied (ADR-0011 decision 8).
            entry.offer = JoinOffer(edition: imported.edition, mintedLineage: imported.lineage,
                                    earlierEdition: earlier.edition, earlierLineage: earlier.lineage)
        }
        entry.edition = imported.edition
        entry.lineage = imported.lineage
        entry.info = imported.info
        entry.refusal = nil
        entry.notes = notes(entry.notes, imported.problems, files: entry.files)
        entries[at] = entry
        save()
        return id
    }

    /// The finder's notes kept, the import's replaced by this import's problems, each volume named as the reader knows it.
    private func notes(_ kept: [EntryNote], _ problems: [Problem], files: [StoredFile]) -> [EntryNote] {
        let found = kept.filter { if case .volumeUnreadable = $0 { false } else { true } }
        return found + problems.map { problem in
            switch problem {
            case .volumeUnreadable(let name, let error):
                let file = files.first { $0.id.uuidString == name }?.fileName ?? name
                return .volumeUnreadable(fileName: file, reason: ImportRefusal(.wire(.core(error)), fileName: { _ in nil }))
            }
        }
    }

    public func cancelImport(_ id: UUID) async {
        if let queued = queue.firstIndex(of: id) {
            queue.remove(at: queued)
            set(id, .cancelled)
            return wake()
        }
        guard let current = running, current.id == id, !current.cancelled else { return }
        current.cancelled = true
        set(id, .cancelling)
        await current.job?.cancel()
    }

    /// Imports a dictionary again: after a cancel or a failure, or a refused one the reader has replaced.
    public func retry(_ id: UUID) {
        guard let at = index(id), running?.id != id, !queue.contains(id) else { return }
        entries[at].refusal = nil
        save()
        enqueue(id)
    }

    // MARK: - Opening

    /// Opens a dictionary: ready, or imported again when the service says it must be (a changed file, a lost index).
    private func open(_ id: UUID, package resolved: DictionaryPackage? = nil) async {
        busy += 1
        defer { busy -= 1; wake() }
        let package: DictionaryPackage
        if let resolved {
            package = resolved
        } else {
            switch resolve(id) {
            case .success(let found): package = found
            case .failure(let unresolved): return set(id, unresolved.phase)
            }
        }
        set(id, .opening)
        let outcome = await backend.open(package)
        guard index(id) != nil else { return }
        switch outcome {
        case .success(.ready(let dict, let edition, _)):
            if let old = handles[id], old != dict { _ = await backend.close(old) }
            handles[id] = dict
            if let at = index(id), entries[at].edition != edition {
                log.error("an open answered edition \(edition.rawValue, privacy: .public), not the one imported")
            }
            set(id, .ready)
            check(id)
        case .success(.needsImport(let reason)):
            log.info("dictionary \(id, privacy: .public) needs an import: \(reason.rawValue, privacy: .public)")
            if let old = handles.removeValue(forKey: id) { _ = await backend.close(old) }
            enqueue(id)
        case .failure(let failure):
            fail(id, ImportRefusal(failure, fileName: { [entries] file in
                entries.lazy.flatMap(\.files).first { $0.id == file }?.fileName
            }))
        }
    }

    /// The package of a stored dictionary, by `PackageResolution`'s rule; locations that moved are kept. Its files are
    /// located from then on by a `LivePackage`, which holds them to the same rule while the dictionary is open.
    private func resolve(_ id: UUID) -> Result<DictionaryPackage, Unresolved> {
        guard let at = index(id) else { return .failure(Unresolved(phase: .missing(fileName: ""))) }
        let rule = PackageResolution(locator: locator)
        let found: PackageResolution.Found
        switch rule.resolve(entries[at].files, root: entries[at].root) {
        case .success(let resolved): found = resolved
        case .failure(let unresolved): return .failure(unresolved)
        }
        if found.changed {
            entries[at].files = found.files
            entries[at].root = found.root
            save()
        }
        let live = LivePackage(found, rule: rule)
        return .success(DictionaryPackage(files: found.files.enumerated().map { position, file in
            PackageFile(spec: file.spec, locate: { live.current(position) })
        }))
    }

    // MARK: - The reader's choices

    public func remove(_ id: UUID) async {
        guard index(id) != nil else { return }
        await cancelImport(id)
        await stopCheck(id)
        queue.removeAll { $0 == id }
        if let dict = handles[id] { _ = await backend.close(dict) }
        forget(id)
        save()
    }

    /// A dictionary as it was when removed, and its place in the order: what Undo puts back (UI review L-09).
    public struct Removed: Sendable {
        public let entry: LibraryEntry
        public let index: Int
    }

    /// Removes `id` as `remove` does, answering what Undo needs to put it back.
    public func removeForUndo(_ id: UUID) async -> Removed? {
        guard let at = index(id) else { return nil }
        let entry = entries[at]
        await remove(id)
        return Removed(entry: entry, index: at)
    }

    /// Undo of a removal: the dictionary back under its own id (its lineage, and every choice kept under it), at its
    /// place, opened again.
    public func restore(_ removed: Removed) {
        guard index(removed.entry.id) == nil else { return }
        entries.insert(removed.entry, at: min(removed.index, entries.count))
        save()
        enqueue(removed.entry.id)
    }

    private func forget(_ id: UUID) {
        entries.removeAll { $0.id == id }
        handles[id] = nil
        phases[id] = nil
        health[id] = nil
        readingStyles[id] = nil
        appleStatus[id] = nil
    }

    // MARK: - Apple dictionaries (ADR-0011)

    /// The bundles an Apple dictionary in the library was converted from: what the sheet says is "Already imported".
    public var importedAppleBundles: Set<String> {
        Set(entries.compactMap { $0.appleSource?.bundleIdentifier })
    }

    /// The conversion folders the library names: what the launch sweep keeps (decision 9). Nil while the library could
    /// not be read, when nothing may be swept: its dictionaries' folders would look unnamed.
    public var appleConversions: Set<UUID>? {
        unreadable == nil ? Set(entries.compactMap { $0.appleSource?.conversion }) : nil
    }

    /// **Adds what a conversion published** in `folder` (`AppleImports/<conversion>/`) through the ordinary import path
    /// (decision 2), its source kept beside it (decision 10). The import mints its lineage, or suggests the join to the
    /// lineage the same bundle had before (decision 8). Answers the new entry's id; nil when the folder holds no
    /// dictionary or the library cannot be written, said in `notices`.
    @discardableResult
    public func addConversion(in folder: URL, source: AppleSourceRecord, languages: LanguagePair?) -> UUID? {
        guard unreadable == nil, let package = convertedPackage(in: folder) else { return nil }
        guard var entry = try? Self.entry(for: package) else {
            notices.append(.finder(.unreadable(fileName: package.mdx.lastPathComponent)))
            return nil
        }
        entry.appleSource = source
        if let languages, languages.search != nil || languages.explanation != nil {
            entry.languages = Languages(proposal: LanguageProposal(pair: languages, basis: .stated))
        }
        entries.append(entry)
        save()
        enqueue(entry.id)
        return entry.id
    }

    /// **Convert Again** (decision 8): the dictionary `id` now reads the files published in `folder`. A new edition is
    /// joined to its lineage by one recorded join the reader can undo (`undoJoin`); an image-only change is a new MDD
    /// under the same edition, and nothing is joined (decision 7). False when `id` is gone or the folder holds no
    /// dictionary.
    @discardableResult
    public func convertAgain(_ id: UUID, in folder: URL, source: AppleSourceRecord) -> Bool {
        guard unreadable == nil, let at = index(id), running?.id != id, !queue.contains(id),
              let package = convertedPackage(in: folder), let made = try? Self.entry(for: package) else { return false }
        entries[at].files = made.files
        entries[at].root = made.root
        entries[at].notes = made.notes
        entries[at].appleSource = source
        entries[at].refusal = nil
        appleStatus[id] = .current
        convertingAgain.insert(id)
        save()
        enqueue(id)
        return true
    }

    /// Records what became of each Apple dictionary's bundle: `installed` is this Mac's bundles by identifier, each
    /// with its source revision now (nil when it could not be read, which offers nothing).
    public func setAppleStatus(installed: [String: InstalledSource], converter: UInt32 = AppleConverter.revision) {
        var status: [UUID: AppleStatus] = [:]
        for entry in entries {
            guard let source = entry.appleSource else { continue }
            status[entry.id] = AppleStatus.of(source, installed: installed[source.bundleIdentifier], converter: converter)
        }
        appleStatus = status
    }

    /// The one dictionary a conversion folder holds, or nil with the finder's problem in `notices`.
    private func convertedPackage(in folder: URL) -> FoundPackage? {
        let found = PackageFinder.find(in: [folder])
        notices += found.problems.map(LibraryNotice.finder)
        return found.packages.count == 1 ? found.packages.first : nil
    }

    // MARK: - Reading style (ADR-0010)

    /// Asks the service what the reading style does to the open dictionary `id`, unless this session already knows or
    /// is asking. A dictionary not open has nothing to report.
    public func loadReadingStyle(_ id: UUID) async {
        switch readingStyles[id] {
        case .read, .reading: return
        case .unavailable, nil: break
        }
        guard let dict = handle(id) else { return }
        readingStyles[id] = .reading
        let outcome = await backend.readingStyle(dict)
        guard index(id) != nil, readingStyles[id] == .reading else { return }
        switch outcome {
        case .success(let style): readingStyles[id] = .read(style)
        case .failure(let failure):
            log.error("the reading style of \(id, privacy: .public) was not reported: \(String(describing: failure), privacy: .public)")
            readingStyles[id] = .unavailable
        }
    }

    // MARK: - Health (WI-12)

    /// Queues a check of the dictionary `id`, open now; one already checked this session is not asked again.
    private func check(_ id: UUID) {
        if case .checked = health[id] { return }
        guard !checks.contains(id), checking?.id != id else { return }
        checks.append(id)
        health[id] = .checking(done: 0, total: 0)
        runChecks()
    }

    private func runChecks() {
        guard checking == nil else { return }
        while let id = checks.first {
            checks.removeFirst()
            guard let dict = handle(id) else {
                health[id] = nil
                continue
            }
            checking = (id, dict, nil)
            Task { await runCheck(id, dict) }
            return
        }
    }

    private func runCheck(_ id: UUID, _ dict: DictId) async {
        let job = await backend.beginHealth(dict) { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.checking?.id == id, case .checking = self.health[id] else { return }
                self.health[id] = .checking(done: done, total: total)
            }
        }
        guard checking?.id == id else { return await job.cancel() }
        checking?.job = job
        let outcome = await job.outcome()
        if checking?.id == id, index(id) != nil {
            switch outcome {
            case .success(let report): health[id] = .checked(report)
            case .failure(let failure):
                log.error("the health check of \(id, privacy: .public) did not finish: \(String(describing: failure), privacy: .public)")
                health[id] = .unavailable
            }
        }
        if checking?.id == id { checking = nil }
        runChecks()
    }

    /// Stops the dictionary's check, queued or running, and forgets it.
    private func stopCheck(_ id: UUID) async {
        checks.removeAll { $0 == id }
        health[id] = nil
        guard let running = checking, running.id == id else { return }
        checking = nil
        await running.job?.cancel()
        runChecks()
    }

    /// Moves dictionaries as a list's drag does: `offsets` taken out, put back before `toOffset`.
    public func move(fromOffsets offsets: IndexSet, toOffset: Int) {
        let moving = offsets.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        var rest = entries.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let at = min(max(0, toOffset - offsets.count(in: 0..<toOffset)), rest.count)
        rest.insert(contentsOf: moving, at: at)
        entries = rest
        save()
    }

    public func moveUp(_ id: UUID) {
        guard let at = index(id), at > 0 else { return }
        entries.swapAt(at, at - 1)
        save()
    }

    public func moveDown(_ id: UUID) {
        guard let at = index(id), at + 1 < entries.count else { return }
        entries.swapAt(at, at + 1)
        save()
    }

    public func setEnabled(_ id: UUID, _ enabled: Bool) {
        update(id) { $0.enabled = enabled }
    }

    /// The reader's own name; nil or blank gives the header's back.
    public func rename(_ id: UUID, _ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.readersName = trimmed?.isEmpty == false ? trimmed : nil }
    }

    /// The reader's languages: theirs from now on, and not asked again.
    public func setLanguages(_ id: UUID, _ pair: LanguagePair) {
        update(id) { $0.languages.pair = pair; $0.languages.basis = .reader; $0.languages.confirmed = true }
    }

    /// The proposal is right, the reader says.
    public func confirmLanguages(_ id: UUID) {
        update(id) { $0.languages.confirmed = true }
    }

    public func dismiss(_ notice: LibraryNotice) {
        notices.removeAll { $0 == notice }
    }

    // MARK: - Lineage

    /// **The reader says the changed edition is the same dictionary**: joins it to the lineage the dictionary had.
    /// A reply lost to a dying service is recovered by asking the edition's lineage, not by joining again.
    public func acceptJoin(_ id: UUID) async -> Bool {
        guard let at = index(id), let offer = entries[at].offer, entries[at].edition == offer.edition else { return false }
        guard await lineage(.join(offer.edition, offer.earlierLineage), expecting: offer.earlierLineage) else { return false }
        update(id) {
            $0.lineage = offer.earlierLineage
            $0.join = LineageJoin(edition: offer.edition, joinedTo: offer.earlierLineage, previous: offer.mintedLineage,
                                  offer: offer)
            $0.offer = nil
        }
        return true
    }

    /// **Undoes the reader's join exactly**: the edition goes back to the lineage its import gave it, and the question is
    /// open again.
    public func undoJoin(_ id: UUID) async -> Bool {
        guard let at = index(id), let join = entries[at].join else { return false }
        guard await lineage(.split(join.edition, join.previous), expecting: join.previous) else { return false }
        update(id) {
            $0.lineage = join.previous
            $0.join = nil
            $0.offer = join.offer
        }
        return true
    }

    /// The reader says the changed edition is a dictionary of its own: it keeps the lineage its import gave it.
    public func declineJoin(_ id: UUID) {
        update(id) { $0.offer = nil }
    }

    private func lineage(_ operation: LineageOperation, expecting: LineageId) async -> Bool {
        if case .success(let answered) = await backend.lineage(operation), answered == expecting { return true }
        let edition: Edition
        switch operation {
        case .join(let asked, _), .split(let asked, _), .of(let asked): edition = asked
        }
        guard case .success(let now) = await backend.lineage(.of(edition)) else { return false }
        return now == expecting
    }

    // MARK: - Keeping

    private func index(_ id: UUID) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout LibraryEntry) -> Void) {
        guard let at = index(id) else { return }
        change(&entries[at])
        save()
    }

    private func set(_ id: UUID, _ phase: EntryPhase) {
        guard index(id) != nil else { return }
        phases[id] = phase
        onPhase?(id, phase)
    }

    private func save() {
        guard unreadable == nil else { return }
        // An Apple dictionary with no open question has settled on its lineage: what a later fresh import suggests.
        for entry in entries where entry.offer == nil {
            guard let source = entry.appleSource, let edition = entry.edition, let lineage = entry.lineage else { continue }
            appleLineages[source.bundleIdentifier] = AppleLineage(edition: edition, lineage: lineage)
        }
        do {
            try store.save(LibraryDocument(entries: entries, appleLineages: appleLineages))
        } catch {
            notices.append(.notSaved(error))
        }
    }
}

/// A dictionary whose package could not be put together, and the phase that says why.
struct Unresolved: Error {
    let phase: EntryPhase
}

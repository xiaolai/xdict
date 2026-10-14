import Foundation
import Synchronization
import XDictClient
import XDictContract
import XDictLibrary

/// **The library with generated packages** (plan-macos-v1 WI-5, done-when; the E2E `library` stage, and
/// `LibraryScenarioTests` in-process): `Tools/build-fixtures.sh`'s `library/` packages, copied into a scratch folder of
/// the run's own, added to a library of the run's own through the service the client reaches. A file and a folder are
/// registered; ordered volumes and a sidecar are found by the bytes the service returns; a missing volume is named; an
/// import is cancelled while it runs and retried to completion while another dictionary answers lookups; a stated
/// language pair is not asked and a guessed one is, and an edit persists; a format 3.0 volume, a registration code and
/// a damaged file are each refused with their own reason; a link out of the chosen folder is refused; missing and
/// unsupported sounds are told apart; a rewritten file becomes a new edition joined only when the reader says so, and
/// the join undoes; a moved folder is found again, and only by relinking.
///
/// Every check is named in `checkNames`, which the stage and the test require in full: a scenario that stopped early
/// leaves one missing.
@MainActor
public struct LibraryScenario {
    public static let checkNames: Set<String> = [
        "file.registered", "folder.registered", "folder.volumesInOrder", "folder.sidecarFound",
        "gap.missingVolumeReported", "cancel.cancelledWhileRunning", "retry.completed", "lookup.answeredDuringImport",
        "languages.statedNotAsked", "languages.guessAsked", "languages.editPersists",
        "refusal.resourceLibraryV3", "refusal.registrationCode", "refusal.damaged", "escape.refused",
        "sounds.toldApart", "changed.newEdition", "changed.notJoinedUnasked", "changed.joined", "changed.persists",
        "changed.undone", "relink.followsAMove", "relink.controlWithoutRelinking",
    ]

    let client: ServiceClient
    let fixtures: URL
    let scratch: URL

    public init(client: ServiceClient, fixtures: URL, scratch: URL) {
        self.client = client
        self.fixtures = fixtures
        self.scratch = scratch
    }

    var work: URL { scratch.appending(path: "library") }
    var storeDirectory: URL { scratch.appending(path: "store") }

    public func run() async -> Findings {
        var findings = Findings()
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixtures.appending(path: "library"), to: work)
        } catch {
            findings.check("setup", false, "the library fixtures could not be copied: \(error)")
            return findings
        }
        let library = Library(store: LibraryStore(directory: storeDirectory), backend: client)
        await library.start()
        let single = await registered(library, &findings)
        await folders(library, &findings)
        await cancelAndRetry(library, answering: single, &findings)
        await languages(library, &findings)
        await refusals(library, &findings)
        await changed(library, &findings)
        await relink(&findings)
        return findings
    }

    // MARK: - File and folder

    /// `file.registered`: one MDX chosen as a file answers a lookup. Answers its handle, for the lookups made while
    /// another import runs.
    func registered(_ library: Library, _ findings: inout Findings) async -> DictId? {
        let id = await add(library, "file/single.mdx", &findings)
        let entry = library.entries.first { $0.id == id }
        let hits = await lookup(library.handle(id), "apple")
        findings.check("file.registered", library.phases[id] == .ready && entry?.info?.title == "Single File"
                       && entry?.edition?.rawValue.hasPrefix("mdx-sha256-v1:") == true && (hits ?? 0) > 0,
                       "phase \(describe(library.phases[id])), title \(entry?.info?.title ?? "none"), edition "
                       + "\(entry?.edition?.rawValue ?? "none"), hits for apple \(hits.map(String.init) ?? "none"); "
                       + "notices \(library.notices)")
        return library.handle(id)
    }

    func folders(_ library: Library, _ findings: inout Findings) async {
        let added = library.add([work.appending(path: "folder")])
        await library.settle("folder", within: Self.step, &findings)
        let vol = library.entries.first { added.contains($0.id) }
        let id = vol?.id
        findings.check("folder.registered", added.count == 1 && id.map { library.phases[$0] == .ready } == true,
                       "\(added.count) added from the folder, phase \(describe(id.flatMap { library.phases[$0] }))")
        let dict = id.flatMap(library.handle)
        let volumes = vol?.files.filter { $0.role == .mdd }.map(\.fileName) ?? []
        let shared = await resource(dict, "shared.bin"), third = await resource(dict, "c.bin")
        findings.check("folder.volumesInOrder", volumes == ["vol.mdd", "vol.1.mdd", "vol.2.mdd"]
                       && shared?.text == "shared from volume 0" && third?.text == "volume 2",
                       "volumes \(volumes); shared.bin \(shared?.text ?? "none") (volume 0's when the order holds); "
                       + "c.bin \(third?.text ?? "none")")
        let sidecars = vol?.files.filter { $0.role == .sidecar }.map(\.fileName) ?? []
        let css = await resource(dict, "vol.css")
        findings.check("folder.sidecarFound", sidecars == ["vol.css"] && css?.text == "body { color: black }\n",
                       "sidecars \(sidecars); vol.css \(css.map { "\($0.resource)" } ?? "none")")

        let gap = await add(library, "gap", &findings)
        let notes = library.entries.first { $0.id == gap }?.notes ?? []
        let farther = await resource(library.handle(gap), "third.bin")
        findings.check("gap.missingVolumeReported", notes == [.missingVolume(fileName: "gap.1.mdd")]
                       && library.phases[gap] == .ready && farther?.text == "volume 2",
                       "notes \(notes), phase \(describe(library.phases[gap])), third.bin \(farther?.text ?? "none")")
    }

    // MARK: - Cancel, retry, and lookups meanwhile (L4)

    /// The 128 MiB file's import cancelled at its first progress report (so while the service is reading it), then
    /// retried to completion while a loop of lookups asks the first dictionary: some of them must be answered between
    /// the retry's first progress report and its answer.
    func cancelAndRetry(_ library: Library, answering dict: DictId?, _ findings: inout Findings) async {
        let phases = PhaseLog()
        library.onPhase = { id, phase in
            phases.events.append((id, phase, .now))
            guard id == phases.target, !phases.cancelSent, case .importing(let done, _) = phase, done > 0 else { return }
            phases.cancelSent = true
            Task { await library.cancelImport(id) }
        }
        defer { library.onPhase = nil }
        let added = library.add([work.appending(path: "big/big.mdx")])
        guard let id = added.first else {
            findings.check("cancel.cancelledWhileRunning", false, "big.mdx was not added: \(library.notices)")
            return
        }
        phases.target = id
        await library.settle("cancel", within: Self.step, &findings)
        let seen = phases.events.filter { $0.0 == id }.map(\.1)
        let reports = seen.compactMap { phase -> (UInt64, UInt64)? in
            if case .importing(let done, let total) = phase, done > 0 { (done, total) } else { nil }
        }
        let midway = reports.first.map { $0.0 < $0.1 } ?? false
        findings.check("cancel.cancelledWhileRunning", library.phases[id] == .cancelled && midway
                       && seen.contains(.cancelling) && library.entries.first { $0.id == id }?.edition == nil,
                       "phase \(describe(library.phases[id])); progress before the cancel \(reports.first.map { "\($0.0)/\($0.1)" } ?? "none")")

        phases.target = nil
        phases.events = []
        let answered = Answered()
        let loop = Task.detached { [client] in
            while !Task.isCancelled {
                guard let dict else { return }
                let outcome = await client.call(.lookup(query: "banana", dicts: [dict], options: Self.page))
                if case .success(let delivered) = outcome, case .page = delivered.answer { answered.add(.now) }
            }
        }
        library.retry(id)
        await library.settle("retry", within: Self.step, &findings)
        loop.cancel()
        _ = await loop.value
        let mine = phases.events.filter { $0.0 == id }
        let running = mine.first { if case .importing(let done, _) = $0.1 { done > 0 } else { false } }?.2
        let answer = mine.first { $0.1 == .opening || $0.1 == .ready }?.2
        let during = running.flatMap { from in answer.map { to in answered.count(in: from...to) } } ?? 0
        findings.check("retry.completed", library.phases[id] == .ready, "phase \(describe(library.phases[id]))")
        findings.check("lookup.answeredDuringImport", during > 0,
                       "\(during) lookups of another dictionary answered while the retried import was running "
                       + "(\(answered.total) in all); import running for "
                       + "\(running.flatMap { from in answer.map { milliseconds($0 - from) } } ?? "?") ms")
        findings.fact("lookupsDuringImport", "\(during)")
    }

    /// How long one step may take to settle; the E2E stage gives the whole scenario 600 s.
    static let step = Duration.seconds(60)

    static let page = LookupOptions(limit: 10, offset: 0, mode: .reader, generation: nil)

    // MARK: - Helpers

    /// Adds one fixture path and waits for it: the new dictionary's id, or a fresh one that matches nothing.
    func add(_ library: Library, _ path: String, _ findings: inout Findings) async -> UUID {
        let added = library.add([work.appending(path: path)])
        await library.settle(path, within: Self.step, &findings)
        return added.first ?? UUID()
    }

    func lookup(_ dict: DictId?, _ query: String) async -> Int? {
        guard let dict, case .success(let delivered) = await client.call(.lookup(query: query, dicts: [dict], options: Self.page)),
              case .page(let page) = delivered.answer else { return nil }
        return page.hits.count
    }

    struct Fetched {
        let resource: Resource
        let bytes: Data?
        var text: String? { bytes.map { String(decoding: $0, as: UTF8.self) } }
    }

    func resource(_ dict: DictId?, _ path: String) async -> Fetched? {
        guard let dict, case .success(let delivered) = await client.call(.resource(dict: dict, path: path, render: .reader)),
              case .resource(let resource) = delivered.answer else { return nil }
        return Fetched(resource: resource, bytes: delivered.payload)
    }

    func describe(_ phase: EntryPhase?) -> String {
        phase.map { "\($0)" } ?? "none"
    }
}

/// The phases one run saw, in order, with when.
@MainActor
final class PhaseLog {
    var events: [(UUID, EntryPhase, ContinuousClock.Instant)] = []
    var target: UUID?
    var cancelSent = false
}

/// When each lookup was answered, from a loop off the main actor.
final class Answered: Sendable {
    private let times = Mutex<[ContinuousClock.Instant]>([])

    func add(_ time: ContinuousClock.Instant) {
        times.withLock { $0.append(time) }
    }

    func count(in range: ClosedRange<ContinuousClock.Instant>) -> Int {
        times.withLock { $0.count { range.contains($0) } }
    }

    var total: Int { times.withLock(\.count) }
}

extension Library {
    /// `settled(within:)`, and a failed check named `settled.<step>` when it was not: an import that never ends is then
    /// a named failure in the report, not an instrument that never writes one.
    func settle(_ step: String, within limit: Duration, _ findings: inout Findings) async {
        if await settled(within: limit) { return }
        let working = entries.compactMap { entry in
            phases[entry.id].flatMap { $0 == .ready ? nil : "\(entry.mdx?.fileName ?? "?"): \($0)" }
        }
        findings.check("settled.\(step)", false, "still working after \(limit): \(working.prefix(5))")
    }
}

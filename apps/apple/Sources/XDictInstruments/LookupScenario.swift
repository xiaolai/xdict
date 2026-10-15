import Foundation
import XDictClient
import XDictContract
import XDictLibrary
import XDictSearch

/// What the lookup scenario needs of the window it runs in, beyond the window's model: the entry pane, to scroll it and
/// read where it is, and moments at which a driver outside the app reads the window as VoiceOver does.
@MainActor
public protocol LookupStage: AnyObject {
    /// Waits until the entry `shown` names is on screen and has landed; false when it never did.
    func landed(_ shown: SearchModel.Shown) async -> Bool
    /// Scrolls the entry on screen to `offset` CSS pixels; answers where it is then.
    func scroll(to offset: Double) async -> Double?
    /// Where the entry on screen is scrolled to.
    func offset() async -> Double?
    /// A moment the driver checks the window from outside, against what the window should say now; its findings, or
    /// none where there is no driver.
    func checkpoint(_ name: String) async -> Findings
}

/// **The main window with generated dictionaries** (plan-macos-v1 WI-6, done-when; the E2E `lookup` stage through the
/// app's own window, and `LookupScenarioTests` in-process with no window): `Tools/build-fixtures.sh`'s `lookup/`
/// dictionaries, added to a library of the run's own, searched through the model of the window the stage gives.
///
/// Switching scope changes the results; reordering the library reorders them; `abbe` finds `abbé` in reader mode only,
/// and the exact `abbe` leads with its reason; the phrase `take off` resolves intact and is suggested; no internal key
/// is ever suggested; no match, indexing, a missing file, a damaged file and an unsupported one are told apart, each with
/// its next action; a dictionary whose replies the check holds delays no other's results, nor takes the entry from an
/// earlier one; a 66,355-record key pages to every record; a five-hop trail of links (each looked up in link mode in its
/// own dictionary) returns exactly, scroll included, with Back, and to the typed word in one step.
///
/// Every check is named in `checkNames`, which the stage and the test require in full: a scenario that stopped early
/// leaves one missing. With the owner's dictionaries (`corpus`), LDOCE's internal keys are checked too.
@MainActor
public final class LookupScenario {
    public static let checkNames: Set<String> = [
        "setup.library", "scope.changesResults", "order.followsTheLibrary", "folding.exactLeads",
        "folding.readerModeOnly", "phrase.resolvesIntact", "phrase.suggested", "internal.neverSuggested",
        "unavailable.toldApart", "unavailable.indexingEnds", "delay.othersNotHeld", "delay.entryKeepsTheOrder",
        "paging.everyRecord", "link.followedInLinkMode", "trail.backReturnsExactly", "trail.forwardReturnsExactly",
        "trail.originInOneStep",
    ]
    /// Checked only with the owner's dictionaries.
    public static let corpusCheckNames: Set<String> = ["internal.ldoce"]

    /// The dictionaries, by their folders in `lookup/`, in the order they are added.
    static let answering = ["alpha", "beta", "records", "damaged", "locked", "gone"]
    static let records = 66_355
    static let hops = 5
    /// How long a check waits for something that should take well under a second.
    static let step: Duration = .seconds(20)

    public let library: Library
    public let model: SearchModel
    let client: ServiceClient
    let hold: TransportHold
    let stage: any LookupStage
    let fixtures: URL
    let scratch: URL
    let corpus: URL?
    var ids: [String: UUID] = [:]
    var work: URL { scratch.appending(path: "lookup") }

    /// `fixtures` is the `lookup/` folder; `hold` is the transport `client` reaches the service through; `corpus` the
    /// owner's dictionaries, for LDOCE.
    public init(library: Library, model: SearchModel, client: ServiceClient, hold: TransportHold, stage: any LookupStage,
                fixtures: URL, scratch: URL, corpus: URL?) {
        self.library = library
        self.model = model
        self.client = client
        self.hold = hold
        self.stage = stage
        self.fixtures = fixtures
        self.scratch = scratch
        self.corpus = corpus
    }

    /// The scenario with no window: a library and a model of its own, a stage that lands entries where the model says.
    public static func headless(client: ServiceClient, hold: TransportHold, fixtures: URL, scratch: URL) async -> Findings {
        let library = Library(store: LibraryStore(directory: scratch.appending(path: "store")), backend: client)
        let model = SearchModel(backend: client, window: "headless") { library.searchSources }
        let stage = ModelStage(model)
        model.scrollReader = { [stage] in await stage.offset() }
        let scenario = LookupScenario(library: library, model: model, client: client, hold: hold, stage: stage,
                                      fixtures: fixtures, scratch: scratch, corpus: nil)
        await library.start()
        var findings = await scenario.setUp()
        guard findings.passed else { return findings }
        findings.merge(await scenario.run())
        return findings
    }

    // MARK: - The library

    /// Copies the dictionaries into the run's folder and adds them to the library, started already: six that answer or
    /// are refused, one whose file is then deleted, and LDOCE when there is a corpus. The one whose import the transport
    /// holds is added by the check that needs it indexing (`unavailable`): the client gives up on an import silent for
    /// a minute (`Deadlines.importSilence`), so it is held no longer than that check.
    public func setUp() async -> Findings {
        var findings = Findings()
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixtures, to: work)
        } catch {
            findings.check("setup.library", false, "the lookup fixtures could not be copied: \(error)")
            return findings
        }
        for name in Self.answering {
            ids[name] = library.add([work.appending(path: "\(name)/\(name).mdx")]).first
        }
        if let ldoce = corpus?.appending(path: "ldoce"), FileManager.default.fileExists(atPath: ldoce.path) {
            ids["ldoce"] = library.add([ldoce]).first
        }
        let settled = await library.settled(within: .seconds(900))
        try? FileManager.default.removeItem(at: work.appending(path: "gone/gone.mdx"))
        await library.refresh()
        model.sourcesDidChange()

        let phases = Self.answering.map { "\($0): \(describe(ids[$0].flatMap { library.phases[$0] }))" }
        let wanted: [String: (EntryPhase?) -> Bool] = [
            "alpha": { $0 == .ready }, "beta": { $0 == .ready }, "records": { $0 == .ready },
            "damaged": { $0 == .refused(.damaged) }, "locked": { $0 == .refused(.registrationCode) },
            "gone": { if case .missing = $0 { true } else { false } },
        ]
        let wrong = wanted.filter { name, ok in !ok(ids[name].flatMap { library.phases[$0] }) }.keys.sorted()
        let ldoce = ids["ldoce"].map { describe(library.phases[$0]) } ?? "absent"
        findings.check("setup.library", settled && wrong.isEmpty && (ldoce != "absent" || corpus == nil),
                       "settled \(settled); \(phases.joined(separator: ", ")); LDOCE \(ldoce); wrong: \(wrong); notices "
                       + "\(library.notices)")
        return findings
    }

    /// Every check, in an order that leaves each one's state for the next only where it says so. `pagingToo: false`
    /// leaves out `paging.everyRecord` (and its checkpoint), the longest check by far, for an E2E run that did not ask
    /// for it (`Tools/e2e.sh`'s `lookup.paging`); no later check reads what paging leaves but the word it searches last.
    public func run(pagingToo: Bool = true) async -> Findings {
        var findings = Findings()
        await scope(&findings)
        await order(&findings)
        await folding(&findings)
        await phrase(&findings)
        await internalKeys(&findings)
        await unavailable(&findings)
        await delay(&findings)
        if pagingToo {
            await paging(&findings)
        } else {
            await search("apple")   // where paging leaves the window, so the trail starts as it always does
        }
        await trail(&findings)
        return findings
    }

    // MARK: - Helpers

    /// Lets every step through the trail and every lookup asked so far finish.
    func settle() async {
        await model.idle()
        await model.answersSettled()
    }

    func search(_ query: String, scope: SearchScope = .all) async {
        model.setScope(scope)
        model.text = query
        model.submit()
        await settle()
    }

    func section(_ name: String) -> ResultSection? {
        guard let id = ids[name] else { return nil }
        return model.sections.first { $0.id == id }
    }

    func results(_ name: String) -> Results? {
        if case .results(let results)? = section(name)?.status { results } else { nil }
    }

    /// The sections with results, by name, in the order shown.
    var answeredNames: [String] {
        model.sections.compactMap { section in
            if case .results = section.status { section.name } else { nil }
        }
    }

    /// `answeredNames` of the run's generated dictionaries alone: the owner's LDOCE, there for its internal keys,
    /// answers common words too, and where it falls among them says nothing about them.
    var answeredGenerated: [String] {
        let generated = Set(ids.filter { $0.key != "ldoce" }.values)
        return model.sections.compactMap { section in
            guard generated.contains(section.id), case .results = section.status else { return nil }
            return section.name
        }
    }

    func describe(_ hits: [Hit]?) -> String {
        guard let hits else { return "no results" }
        return hits.prefix(6).map { "\($0.headword) (\($0.how))" }.joined(separator: ", ")
    }

    func describe(_ phase: EntryPhase?) -> String {
        phase.map { String(describing: $0) } ?? "none"
    }

    /// Polls `condition` until it holds or `limit` passes; whether it held.
    func until(_ limit: Duration, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    /// The core's suggestions for `prefix` in one dictionary, asked directly: what the window's model asks.
    func suggestions(_ prefix: String, in name: String) async -> [String]? {
        guard let handle = ids[name].flatMap(library.handle) else { return nil }
        let outcome = await client.call(.suggest(prefix: prefix, dicts: [handle], limit: 100))
        guard case .success(let delivered) = outcome, case .suggestions(let keys) = delivered.answer else { return nil }
        return keys
    }

    /// The core's answer for `query` in one dictionary, asked directly in `mode`.
    func lookup(_ query: String, in name: String, mode: MatchMode) async -> Page? {
        guard let handle = ids[name].flatMap(library.handle) else { return nil }
        let outcome = await client.call(.lookup(query: query, dicts: [handle], options: LookupOptions(
            limit: 10, offset: 0, mode: mode, generation: nil)))
        guard case .success(let delivered) = outcome, case .page(let page) = delivered.answer else { return nil }
        return page
    }
}

/// The stage with no window: an entry lands where the model says, and stays where it was scrolled.
@MainActor
final class ModelStage: LookupStage {
    let model: SearchModel
    private var at = 0.0

    init(_ model: SearchModel) {
        self.model = model
    }

    func landed(_ shown: SearchModel.Shown) async -> Bool {
        guard model.shown == shown else { return false }
        at = if case .offset(let y) = shown.landing { y } else { 0 }
        return true
    }

    func scroll(to offset: Double) async -> Double? {
        at = offset
        return at
    }

    func offset() async -> Double? { at }

    func checkpoint(_ name: String) async -> Findings { Findings() }
}

import Foundation
import Testing
import XDictClient
import XDictContract
import XDictSearch
import XDictTestSupport
import XDictUI

/// A backend that answers one scripted outcome, records what it was asked, and can hold its answer until the test
/// releases it — enough to see the keep's calls and its superseded-late-answer rule.
actor ScriptedLookupBackend: SearchBackend {
    private let outcome: ClientOutcome
    private let gate: Gate?
    private(set) var requests: [ServiceOperation] = []

    init(_ outcome: ClientOutcome, gate: Gate? = nil) {
        self.outcome = outcome
        self.gate = gate
    }

    func queue(_ operations: [ServiceOperation], as caller: Caller, superseding: Bool) async -> [PendingCall] { [] }
    func supersede(_ caller: Caller) async {}

    func request(_ operation: ServiceOperation) async -> ClientOutcome {
        requests.append(operation)
        if let gate { await gate.wait() }
        return outcome
    }
}

/// A one-shot gate: `open()` releases every `wait()` that is waiting, and every later wait returns at once.
actor Gate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// What a keep asked the note path to write.
@MainActor
final class SaveLog {
    var calls: [(target: MeaningTarget, text: String, replacing: Bool)] = []
    var next: StudyModel.NoteSave = .saved(PhraseKeepTests.note())
}

/// **The keep's mechanism, without a window** (plan-context-tools WI-3): one lookup of the dictionary's spelling, the
/// entry that lookup found, and one note whose text is the phrase — never the sentence; a keep superseded by the sentence
/// moving on writes nothing.
@MainActor
struct PhraseKeepTests {
    static let dict = DictId(rawValue: "handle-tiny")
    static let edition = Edition(rawValue: "mdx-sha256-v1:aa")

    static func candidate(_ phrase: String = "take something into account") -> PhraseRow.Candidate {
        PhraseRow.Candidate(dict: dict, phrase: phrase, separation: .none, gap: 0,
                            span: NSRange(location: 12, length: 10))
    }

    static func page(key: String = "take something into account", occurrence: UInt32 = 2) -> Page {
        let hit = Hit(dict: dict, entry: EntryRef(edition: edition, key: key, occurrence: occurrence), headword: key,
                      how: .exact, problems: [])
        return Page(hits: [hit], total: 1, generation: 1, problems: [])
    }

    /// A lookup that found nothing: the phrase's key is a dangling redirect or gone from this edition.
    static func emptyPage() -> Page {
        Page(hits: [], total: 0, generation: 1, problems: [])
    }

    /// A note the save path hands back; its content is the test's own, never a dictionary's.
    static func note() -> StudyNote {
        StudyNote(target: StudyTarget(lineage: "lineage-a", entryKey: "take something into account", occurrence: 2,
                                      kind: .entry, edition: edition.rawValue, definitionHash: "h"),
                  text: "take something into account", at: 1, device: "d")
    }

    static func keeper(_ backend: ScriptedLookupBackend, _ log: SaveLog) -> PhraseKeeper {
        PhraseKeeper(backend: backend) { target, text, replacing in
            log.calls.append((target, text, replacing))
            return log.next
        }
    }

    @Test func theKeepLooksThePhraseUpAndWritesItsOwnEntryAsANote() async {
        let backend = ScriptedLookupBackend(.success(Delivered(answer: .page(Self.page()), payload: nil)))
        let log = SaveLog()
        let keeper = Self.keeper(backend, log)
        await keeper.keep(Self.candidate())
        #expect(keeper.state == .kept)
        let requests = await backend.requests
        guard requests.count == 1, case .lookup(let query, let dicts, let options) = requests[0] else {
            Issue.record("the keep made no lookup: \(String(describing: requests))")
            return
        }
        #expect(query == "take something into account")
        #expect(dicts == [Self.dict])
        #expect(options.limit == 1)
        #expect(log.calls.count == 1)
        #expect(log.calls.first?.target == MeaningTarget(dictionary: Self.dict,
                                                         entry: EntryRef(edition: Self.edition,
                                                                         key: "take something into account",
                                                                         occurrence: 2)))
        #expect(log.calls.first?.text == "take something into account", "the note is the phrase, never the sentence")
        #expect(log.calls.first?.replacing == false, "an existing note is never overwritten without the reader's yes")
    }

    @Test func aPhraseWhoseLookupFindsNothingIsAStatedFailure() async {
        let backend = ScriptedLookupBackend(.success(Delivered(answer: .page(Self.emptyPage()), payload: nil)))
        let log = SaveLog()
        let keeper = Self.keeper(backend, log)
        await keeper.keep(Self.candidate())
        #expect(keeper.state == .failed)
        #expect(log.calls.isEmpty, "nothing was written")
    }

    @Test func anExistingNoteAsksBeforeReplacingAndTheYesReplaces() async {
        let backend = ScriptedLookupBackend(.success(Delivered(answer: .page(Self.page()), payload: nil)))
        let log = SaveLog()
        log.next = .needsReplacement
        let keeper = Self.keeper(backend, log)
        await keeper.keep(Self.candidate())
        #expect(keeper.state == .needsReplacement)
        log.next = .saved(Self.note())
        await keeper.keep(Self.candidate(), replacing: true)
        #expect(keeper.state == .kept)
        #expect(log.calls.last?.replacing == true)
    }

    @Test func aKeepSupersededByTheSentenceMovingOnWritesNothing() async {
        let gate = Gate()
        let backend = ScriptedLookupBackend(.success(Delivered(answer: .page(Self.page()), payload: nil)), gate: gate)
        let log = SaveLog()
        let keeper = Self.keeper(backend, log)
        let keeping = Task { await keeper.keep(Self.candidate()) }
        // The lookup is in flight; the next capture resets the keep, as `holdMeaning` does.
        #expect(await MeaningSessionTests.waitUntil { keeper.state == .keeping })
        keeper.reset()
        await gate.release()
        await keeping.value
        #expect(keeper.state == .idle, "a superseded keep presents nothing")
        #expect(log.calls.isEmpty, "and writes no card")
    }

    @Test func aMissingDictionaryIsAStatedFailure() {
        let backend = ScriptedLookupBackend(.success(Delivered(answer: .page(Self.page()), payload: nil)))
        let keeper = PhraseKeeper(backend: backend) { _, _, _ in .failed }
        keeper.fail(Self.candidate())
        #expect(keeper.state == .failed)
        #expect(keeper.state(for: Self.candidate()) == .failed, "the failure is this phrase's own")
        #expect(keeper.state(for: Self.candidate("look the word up")) == .idle,
                "another candidate never inherits the previous phrase's state")
        #expect(keeper.state(for: PhraseRow.Candidate(dict: DictId(rawValue: "handle-other"),
                                                      phrase: "take something into account", separation: .none,
                                                      gap: 0, span: NSRange(location: 0, length: 1))) == .idle,
                "the same phrase in another dictionary is another candidate")
    }
}

/// **The switch and the capture rule** (plan-context-tools WI-4; owner Q2): off means the phrase question is never asked;
/// a phrase ask is already about its phrase; a capture with no term range cannot be asked.
@MainActor
struct PhraseQuestionTests {
    @Test func theSwitchStopsTheRequestItself() {
        let range = NSRange(location: 4, length: 3)
        #expect(SearchWindowState.phraseQuestion(shown: false, phrase: nil, range: range) == .cleared)
        #expect(SearchWindowState.phraseQuestion(shown: true, phrase: nil, range: range)
                == .asked(PhraseTerm(location: 4, length: 3)))
        #expect(SearchWindowState.phraseQuestion(shown: true, phrase: "take something into account", range: range)
                == .cleared)
        #expect(SearchWindowState.phraseQuestion(shown: true, phrase: nil, range: nil) == .cleared)
    }

    @Test func theKeepIsReachableOnBothSurfacesWithoutAPointer() throws {
        // Tests/XDictUITests/<this file> → apps/apple, which holds Sources/.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in ["Sources/XDictUI/LookupPanelView.swift", "Sources/XDictUI/MeaningAnswerView.swift"] {
            let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            #expect(text.contains("PhraseKeepControl("), "\(path) does not draw the keep control")
        }
        let panel = try String(contentsOf: root.appending(path: "Sources/XDictUI/LookupPanelView.swift"),
                               encoding: .utf8)
        #expect(panel.contains("Keep as a Card"), "the row offers the keep from its context menu, not only a pointer")
        #expect(panel.contains("accessibilityIdentifier(\"\\(identifier).keep\")"))
    }
}

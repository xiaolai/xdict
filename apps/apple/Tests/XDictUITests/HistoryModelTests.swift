import AppKit
import CoreGraphics
import Foundation
import Testing
import XDictCapture
import XDictClient
import XDictContract
import XDictLibrary
import XDictTokens
import XDictUI

/// The reading history's app side (ADR-0023, ADR-0024): when a finished document is a reading, what the app makes of one,
/// and what the model asks the core. Storage, grouping and the language filter's decision are the core's, tested there.
struct HistoryCaptureTests {
    @Test func onlyAnEntryThatDrewOnScreenWithASentenceIsRecorded() {
        #expect(HistoryCapture(onScreen: true, current: true, hasEntry: true, hasSentence: true).records)
        // A lookup closed before its entry loaded.
        #expect(!HistoryCapture(onScreen: false, current: true, hasEntry: true, hasSentence: true).records)
        // A no-results lookup: there is no entry to read.
        #expect(!HistoryCapture(onScreen: true, current: true, hasEntry: false, hasSentence: true).records)
        // A stale completion, in the gap before a newer lookup's entry request.
        #expect(!HistoryCapture(onScreen: true, current: false, hasEntry: true, hasSentence: true).records)
        // A typed search, or a capture with no sentence: nothing to put on a card.
        #expect(!HistoryCapture(onScreen: true, current: true, hasEntry: true, hasSentence: false).records)
    }
}

struct ReadingCaptureTests {
    static let entry = EntryRef(edition: Edition(rawValue: "mdx-sha256-v1:aa"), key: "hold", occurrence: 2)

    @Test func aCappedSentenceCarriesItsCutAndQuality() {
        let handoff = MeaningHandoff(term: "hold", sentence: "They hold that view.", range: NSRange(location: 5, length: 4),
                                     cut: [.end], origin: MeaningOrigin(request: 1, generation: 2))
        let reading = ReadingCapture.reading(handoff: handoff, entry: Self.entry, dictionary: nil,
                                             at: Date(timeIntervalSince1970: 1_790_641_800.9), device: "d")
        #expect(reading.surface == "hold")
        #expect(reading.lemma == "hold")
        #expect(reading.sentence == "They hold that view.")
        #expect(reading.span == LedgerSpan(start: 5, len: 4))
        #expect(reading.cut == 2, "bit 1: the end was cut")
        #expect(reading.quality == "mayBeCut")
        #expect(reading.edition == "mdx-sha256-v1:aa")
        #expect(reading.entryKey == "hold")
        #expect(reading.occurrence == 2)
        #expect(reading.at == 1_790_641_800, "whole epoch seconds")
        #expect(reading.device == "d")
        #expect(reading.dictionaryName.isEmpty && reading.language.isEmpty, "an unknown dictionary says so")
    }

    @Test func aWholeSentenceIsCompleteAndTheDictionaryIsNamed() {
        let handoff = MeaningHandoff(term: "run", sentence: "They run each day.", range: NSRange(location: 5, length: 3),
                                     origin: MeaningOrigin(request: 1, generation: 1))
        var dictionary = LibraryEntry(
            id: UUID(), root: StoredLocation(bookmark: Data(), path: "/tmp/Tiny"),
            files: [], languages: Languages(proposal: LanguageProposal(pair: LanguagePair(search: "en", explanation: "zh-Hans"),
                                                                      basis: .stated)))
        dictionary.readersName = "Tiny"
        let reading = ReadingCapture.reading(handoff: handoff, entry: Self.entry, dictionary: dictionary,
                                             at: Date(timeIntervalSince1970: 1_790_641_800), device: "d")
        #expect(reading.cut == 0)
        #expect(reading.quality == "complete")
        #expect(reading.language == "en")
        #expect(reading.dictionaryName == "Tiny")
    }

    @Test func theDeviceIsMintedOnceAndKept() throws {
        let name = "xdict-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = DeviceIdentity.current(defaults: defaults)
        #expect(!first.isEmpty)
        #expect(DeviceIdentity.current(defaults: defaults) == first)
    }
}

/// A service that answers the two ledger calls and records what it was asked.
actor FakeHistoryService: HistoryService {
    private(set) var operations: [ServiceOperation] = []
    var history: LedgerHistory
    var outcomes: [LedgerRecordOutcome]

    init(history: LedgerHistory = LedgerHistory(days: []), outcomes: [LedgerRecordOutcome] = [.recorded]) {
        self.history = history
        self.outcomes = outcomes
    }

    func call(_ operation: ServiceOperation) async -> ClientOutcome {
        operations.append(operation)
        switch operation {
        case .ledgerHistory:
            return .success(Delivered(answer: .ledgerHistory(history), payload: nil))
        case .ledgerRemove, .ledgerRestore:
            return .success(Delivered(answer: .ledgerRecord(outcomes.isEmpty ? .recorded : outcomes.removeFirst()),
                                      payload: nil))
        case .ledgerRecord:
            let outcome = outcomes.isEmpty ? .recorded : outcomes.removeFirst()
            return .success(Delivered(answer: .ledgerRecord(outcome), payload: nil))
        default:
            return .failure(.wire(.refused(.unsupportedOperation)))
        }
    }

    func recorded() -> [ServiceOperation] {
        operations.filter { if case .ledgerRecord = $0 { return true } else { return false } }
    }
}

@MainActor
struct HistoryModelTests {
    static func scratch() throws -> (LearningPreferences, UserDefaults, String) {
        let name = "xdict-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (LearningPreferences(defaults: defaults), defaults, name)
    }

    static func reading(_ surface: String = "hold") -> LedgerReading {
        LedgerReading(surface: surface, lemma: surface, sentence: "They \(surface) that view.",
                      span: LedgerSpan(start: 5, len: UInt32(surface.utf16.count)), cut: 0, quality: "complete",
                      edition: "mdx-sha256-v1:aa", entryKey: surface, occurrence: 0, dictionaryName: "Tiny",
                      language: "en", at: 1_790_641_800, device: "d")
    }

    @Test func theHistoryOffWritesNothingAndAsksNothing() async throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        preferences.historyEnabled = false
        let service = FakeHistoryService()
        let model = HistoryModel(service: service, preferences: preferences)
        #expect(await model.record(Self.reading()) == nil)
        let calls = await service.operations
        #expect(calls.isEmpty, "off means no call, not a call the core skips")
        await model.refresh()
        #expect(model.state == .off)
        let afterRefresh = await service.operations
        #expect(afterRefresh.isEmpty)
    }

    @Test func aReadingIsRecordedWithTheReadersTargets() async throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        preferences.setTargetLanguages(["en"])
        let service = FakeHistoryService()
        let model = HistoryModel(service: service, preferences: preferences)
        #expect(await model.record(Self.reading()) == .recorded)
        let calls = await service.recorded()
        #expect(calls.count == 1)
        guard case .ledgerRecord(let reading, _, let targets) = try #require(calls.first) else {
            Issue.record("not a record call")
            return
        }
        #expect(reading.surface == "hold")
        #expect(targets == ["en"])
    }

    @Test func anUncertainCommitIsRetriedWithTheSameOperation() async throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let service = FakeHistoryService(outcomes: [.uncertain, .duplicate])
        let model = HistoryModel(service: service, preferences: preferences)
        #expect(await model.record(Self.reading()) == .duplicate)
        let calls = await service.recorded()
        #expect(calls.count == 2)
        var operations: [String] = []
        for call in calls {
            guard case .ledgerRecord(_, let operation, _) = call else { continue }
            operations.append(operation)
        }
        #expect(Set(operations).count == 1, "a retry reuses the operation id, so the log holds one event")
    }

    @Test func theDrawerFiltersWhatWasLoadedAndNeverRewritesIt() async throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let english = LedgerCard(reading: Self.reading("hold"), times: 1, events: ["e1"])
        let chinese = LedgerReading(surface: "词", lemma: "词", sentence: "这是一个词。", span: nil, cut: 0,
                                    quality: "complete", edition: "mdx-sha256-v1:aa", entryKey: "词", occurrence: 0,
                                    dictionaryName: "Tiny", language: "zh-Hans", at: english.reading.at, device: "d")
        let history = LedgerHistory(days: [
            LedgerDay(id: "2026-09-29", start: 1_790_640_000, label: .yesterday,
                      cards: [LedgerCard(reading: chinese, times: 1, events: ["e2"]), english]),
        ])
        let service = FakeHistoryService(history: history)
        let model = HistoryModel(service: service, preferences: preferences)
        await model.refresh()
        #expect(model.state == .loaded(history))
        #expect(model.days.first?.cards.count == 2, "no filter: every stored reading")
        #expect(model.storedLanguages == ["en", "zh-Hans"])

        preferences.setDrawerLanguages(["en"])
        #expect(model.days.first?.cards.map(\.reading.surface) == ["hold"])
        preferences.setDrawerLanguages(["zh-Hans"])
        #expect(model.days.first?.cards.map(\.reading.surface) == ["词"])
        // The stored history is untouched: the filter is a view of it.
        #expect(model.state == .loaded(history))
    }
}

/// **A history card can be removed, and the removal undone** (owner, 2026-10-21: a misread word must be removable;
/// XiaolaiDict's E4: undo, not a confirmation dialog). The tombstone names the card's own event ids and carries nothing
/// of the sentence.
@MainActor
struct HistoryRemovalTests {
    @Test func removingACardNamesItsEventsAndUndoGivesThemBack() async throws {
        let name = "xdict-removal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let card = LedgerCard(reading: HistoryModelTests.reading("hold"), times: 2, events: ["e1", "e2"])
        let service = FakeHistoryService()
        let model = HistoryModel(service: service, preferences: LearningPreferences(defaults: defaults),
                                 now: { Date(timeIntervalSince1970: 1_790_641_800) }, device: { "d" })
        #expect(await model.remove(card) == .recorded)
        let removal = try #require(model.lastRemoval)
        #expect(removal.eventIds == ["e1", "e2"], "the tombstone names the card's own events")
        #expect(removal.at == 1_790_641_800 && removal.device == "d")
        let sent = await service.operations
        // The last call is the refresh the removal asks for, so the remove is the last call of its own kind.
        let removeCall = sent.last { if case .ledgerRemove = $0 { return true } else { return false } }
        guard case .ledgerRemove(let asked, let operation) = try #require(removeCall) else {
            Issue.record("not a remove call")
            return
        }
        #expect(asked == removal)
        #expect(!operation.isEmpty)

        #expect(await model.restoreLast() == .recorded)
        #expect(model.lastRemoval == nil, "the undo is spent")
        let after = await service.operations
        let restoreCall = after.last { if case .ledgerRestore = $0 { return true } else { return false } }
        guard case .ledgerRestore(let restore, _) = try #require(restoreCall) else {
            Issue.record("not a restore call")
            return
        }
        #expect(restore == removal)
    }
}

/// **A history card's tint** (owner, 2026-10-21): chosen from the card's own identity, so a lookup keeps its colour across
/// launches while the drawer is not one colour.
struct HistoryCardTintTests {
    @Test func theColourIsTheCardsOwnAndDoesNotMoveBetweenLaunches() {
        let one = HistoryCardTint.colour(for: ["0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"]).nsColor
        #expect(one == HistoryCardTint.colour(for: ["0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"]).nsColor)
        #expect(HistoryCardTint.colour(for: []).nsColor == HistoryCardTint.palette[0].nsColor)
    }

    @Test func manyCardsUseMostOfThePalette() {
        let cards = (0..<200).map { "event-\($0)" }
        let used = Set(cards.map { HistoryCardTint.colour(for: [$0]).nsColor })
        #expect(used.count >= HistoryCardTint.palette.count - 1, "\(used.count) of \(HistoryCardTint.palette.count) tints")
    }
}

/// **The learning settings** (ADR-0023): on for a new reader, every language by default, and both language sets survive a
/// relaunch. The recording filter's core-side rule is the ledger's test; this is what the panes store.
@MainActor
struct LearningPreferencesTests {
    static func scratch() throws -> (LearningPreferences, UserDefaults, String) {
        let name = "xdict-learning-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (LearningPreferences(defaults: defaults), defaults, name)
    }

    @Test func aNewReaderHasTheHistoryOnAndEveryLanguage() throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(preferences.historyEnabled, "ADR-0023: a history that begins empty is a failed feature")
        #expect(preferences.targetLanguages.isEmpty)
        #expect(preferences.drawerLanguages.isEmpty)
        #expect(preferences.records(""))
        #expect(preferences.records("zh-Hans"))
        #expect(preferences.shows("zh-Hans"))
    }

    /// **The sync folder is a bookmark** (plan §2.6): kept until the reader clears it, so a moved folder still resolves.
    @Test func theSyncFolderIsRememberedAndCanBeCleared() throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(preferences.syncFolder == nil, "no folder until the reader chooses one")
        preferences.setSyncFolder(Data([1, 2, 3]))
        #expect(preferences.syncFolder == Data([1, 2, 3]))
        preferences.setSyncFolder(nil)
        #expect(preferences.syncFolder == nil)
    }

    @Test func theSettingsSurviveARelaunch() throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        preferences.historyEnabled = false
        preferences.setTargetLanguages(["en", "en", "zh-Hans"])
        preferences.setDrawerLanguages(["en"])
        let relaunched = LearningPreferences(defaults: defaults)
        #expect(!relaunched.historyEnabled)
        #expect(relaunched.targetLanguages == ["en", "zh-Hans"])
        #expect(relaunched.drawerLanguages == ["en"])
        #expect(relaunched.records("zh-Hans"))
        #expect(relaunched.records("en"))
        #expect(!relaunched.records("fr"), "a language outside the set is not recorded")
    }

    @Test func anUnknownLanguageIsNeverATargetUnlessTheSetIsEmpty() throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        preferences.setTargetLanguages(["en"])
        #expect(!preferences.records(""), "unknown is not silently a target")
        preferences.setTargetLanguages([])
        #expect(preferences.records(""))
    }
}

/// **The card marks its word** (plan-history-and-learning §1): spans are UTF-16 units, as the capture contract states, and
/// a capture's cut ends show as ellipses.
struct HistoryRunsTests {
    @Test func theWordIsMarkedInAPlainSentence() {
        #expect(HistoryRuns.runs(sentence: "They hold that view.", span: LedgerSpan(start: 5, len: 4), cut: 0)
                == [.text("They "), .word("hold"), .text(" that view.")])
    }

    @Test func cjkAndEmojiSpansUseUTF16Units() {
        #expect(HistoryRuns.runs(sentence: "这是一个词。", span: LedgerSpan(start: 4, len: 1), cut: 0)
                == [.text("这是一个"), .word("词"), .text("。")])
        // "a 😀 word": a, space, the two-unit emoji, space, then the word at offset 5.
        #expect(HistoryRuns.runs(sentence: "a 😀 word", span: LedgerSpan(start: 5, len: 4), cut: 0)
                == [.text("a 😀 "), .word("word")])
    }

    @Test func cutEndsShowEllipses() {
        #expect(HistoryRuns.runs(sentence: "hold that", span: LedgerSpan(start: 0, len: 4), cut: 3)
                == [.text("…"), .word("hold"), .text(" that"), .text("…")])
        #expect(HistoryRuns.runs(sentence: "to hold", span: LedgerSpan(start: 3, len: 4), cut: 1)
                == [.text("…"), .text("to "), .word("hold")])
    }

    @Test func aSpanOutsideTheSentenceIsClampedAndNeverCrashes() {
        #expect(HistoryRuns.runs(sentence: "hold", span: LedgerSpan(start: 99, len: 4), cut: 0) == [.text("hold")])
        #expect(HistoryRuns.runs(sentence: "hold", span: nil, cut: 0) == [.text("hold")])
    }
}

/// **The drawer hangs under the menu-bar item and stays on the screen** (plan-history-and-learning §1): the final rect is
/// computed before the window is shown, for any screen and any item position.
struct HistoryDrawerGeometryTests {
    static let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    static func geometry(visible: CGRect = screen, screen: CGRect = screen, width: CGFloat = Tokens.Window.historyDrawerWidth)
        -> HistoryDrawerGeometry {
        HistoryDrawerGeometry.make(width: width, visible: visible, screen: screen,
                                   cornerRadius: Tokens.Window.drawerCornerRadius,
                                   shadowMargin: Tokens.Window.drawerShadowMargin)
    }

    /// **Full height at the display's right edge** (plan §1, XiaolaiDict's docked drawer): the width is the token, the
    /// height is the whole visible frame, and the corners against the edge stay square the way system panels do.
    @Test func theDrawerIsFullHeightAtTheDisplaysRightEdge() {
        let g = Self.geometry()
        #expect(g.content.width == Tokens.Window.historyDrawerWidth)
        #expect(g.content.height == Self.screen.height)
        #expect(g.content.maxX == Self.screen.maxX)
        #expect(g.isFlush, "the visible frame reaches the display's edge: no Dock on that side")
        #expect(g.squaresTrailingCorners)
        // The window is grown for the shadow and clipped to the display: it never reaches past the edge.
        #expect(g.window.maxX == Self.screen.maxX)
        #expect(g.window.minX < g.content.minX)
    }

    /// With the Dock on the right the visible frame stops short of the display's edge, and a drawer that squared its
    /// corners there would look cut off in mid-air.
    @Test func aDockOnTheRightTakesTheEdgeAway() {
        let visible = CGRect(x: 0, y: 0, width: 1_360, height: 900)
        let g = Self.geometry(visible: visible)
        #expect(!g.isFlush)
        #expect(!g.squaresTrailingCorners)
        #expect(g.content.maxX == visible.maxX)
    }

    /// A display narrower than the drawer is not overrun: the thickness is clamped to what is there.
    @Test func aDisplayNarrowerThanTheDrawerIsNotOverrun() {
        let visible = CGRect(x: 0, y: 0, width: 300, height: 700)
        let g = Self.geometry(visible: visible)
        #expect(g.content.width == 300)
        #expect(g.content.minX == 0)
    }

    /// Hidden, the content is parked past the window's docked edge, where the window's clip hides every pixel of it.
    @Test func theContentParksPastTheWindowWhenHidden() {
        let g = Self.geometry()
        #expect(g.contentOrigin.x + g.hiddenOffset.width >= g.window.width)
    }
}

/// **Which click asks for the menu** (ported from XiaolaiDict): a right click, and a control click — the system's rule, so a
/// reader with secondary click switched off still reaches the menu.
struct StatusItemClickTests {
    static func event(_ type: NSEvent.EventType, control: Bool = false) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: control ? .control : [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
    }

    @Test func aRightOrControlClickAsksForTheMenu() {
        #expect(StatusItemClick.isSecondary(Self.event(.rightMouseDown)))
        #expect(StatusItemClick.isSecondary(Self.event(.rightMouseUp)))
        #expect(StatusItemClick.isSecondary(Self.event(.leftMouseUp, control: true)))
        #expect(!StatusItemClick.isSecondary(Self.event(.leftMouseUp)))
        #expect(!StatusItemClick.isSecondary(nil), "a VoiceOver press carries no mouse event: the history, not the menu")
    }
}

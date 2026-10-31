import AppKit
import Foundation
import SwiftUI
import Testing
import XDictClient
import XDictContract
import XDictLibrary
import XDictSearch
import XDictTokens
import XDictUI

/// A history service whose answers the test sets one call at a time: a failed read, then a good one.
actor ScriptedHistoryService: HistoryService {
    var history: LedgerHistory
    var failNextReads: Int
    var failRemovals = false
    private(set) var operations: [ServiceOperation] = []

    init(history: LedgerHistory = LedgerHistory(days: []), failNextReads: Int = 0) {
        self.history = history
        self.failNextReads = failNextReads
    }

    func setFailRemovals(_ fail: Bool) { failRemovals = fail }

    func call(_ operation: ServiceOperation) async -> ClientOutcome {
        operations.append(operation)
        switch operation {
        case .ledgerHistory:
            if failNextReads > 0 {
                failNextReads -= 1
                return .failure(.wire(.refused(.unsupportedOperation)))
            }
            return .success(Delivered(answer: .ledgerHistory(history), payload: nil))
        case .ledgerRemove where failRemovals:
            return .failure(.wire(.refused(.unsupportedOperation)))
        case .ledgerRemove, .ledgerRestore:
            return .success(Delivered(answer: .ledgerRecord(.recorded), payload: nil))
        default:
            return .failure(.wire(.refused(.unsupportedOperation)))
        }
    }
}

/// **UI43, UI44**: removal is reachable without hover, and its undo outlives the notice that announces it.
@MainActor
struct HistoryRemovalReachTests {
    static func model(_ service: ScriptedHistoryService) throws -> (HistoryModel, UserDefaults, String) {
        let name = "xdict-reach-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let model = HistoryModel(service: service, preferences: LearningPreferences(defaults: defaults),
                                 now: { Date(timeIntervalSince1970: 1_790_641_800) }, device: { "d" })
        return (model, defaults, name)
    }

    @Test func theNoticeGoesButTheUndoStays() async throws {
        let service = ScriptedHistoryService()
        let (model, defaults, name) = try Self.model(service)
        defer { defaults.removePersistentDomain(forName: name) }
        let card = LedgerCard(reading: HistoryModelTests.reading("hold"), times: 1, events: ["e1"])
        await model.remove(card)
        #expect(model.removalNoticeShown, "a removal announces itself")
        model.dismissRemovalNotice()
        #expect(!model.removalNoticeShown, "the notice's time is up")
        #expect(model.lastRemoval != nil, "the undo is still there after the notice went")
        #expect(await model.restoreLast() == .recorded, "a reader who takes longer still gets the card back")
        #expect(model.lastRemoval == nil && !model.removalNoticeShown)
    }

    @Test func aRefusedRemovalIsSaidAndLeavesNoUndo() async throws {
        let service = ScriptedHistoryService()
        await service.setFailRemovals(true)
        let (model, defaults, name) = try Self.model(service)
        defer { defaults.removePersistentDomain(forName: name) }
        let card = LedgerCard(reading: HistoryModelTests.reading("hold"), times: 1, events: ["e1"])
        #expect(await model.remove(card) == nil)
        #expect(model.removalFailed, "a failure is said, never a silent no-op")
        #expect(model.lastRemoval == nil)
    }

    @Test func everyCardActionIsReachableWithoutAPointer() {
        // One list feeds the context menu and the VoiceOver actions; Remove is in it, not only behind a hover.
        let all = HistoryCardAction.actions(canNote: true, canOpen: true)
        #expect(all == [.openEntry, .note, .remove])
        #expect(HistoryCardAction.actions(canNote: false, canOpen: false) == [.remove],
                "Remove never depends on the other surfaces being wired")
    }
}

/// **UI50**: a failed read says so, offers Try Again, and a retry that succeeds shows the list — never "Nothing yet".
@MainActor
struct HistoryRetryTests {
    @Test func aFailedReadOffersRetryAndIsNotAnEmptyList() async throws {
        let card = LedgerCard(reading: HistoryModelTests.reading("hold"), times: 1, events: ["e1"])
        let day = LedgerDay(id: "d1", start: 1_790_640_000, label: .today, cards: [card])
        let service = ScriptedHistoryService(history: LedgerHistory(days: [day]), failNextReads: 1)
        let (model, defaults, name) = try HistoryRemovalReachTests.model(service)
        defer { defaults.removePersistentDomain(forName: name) }
        await model.refresh()
        let failed = try #require(HistoryNotice.of(model.state, isEmpty: model.days.isEmpty))
        #expect(failed == .failed && failed.offersRetry)
        #expect(HistoryNotice.of(.loaded(LedgerHistory(days: [])), isEmpty: true) == .empty)
        #expect(HistoryNotice.empty.offersRetry == false && HistoryNotice.off.offersRetry == false)
        await model.refresh()
        #expect(HistoryNotice.of(model.state, isEmpty: model.days.isEmpty) == nil, "the retry shows the cards")
        #expect(model.days.count == 1)
    }
}

/// **UI46, UI48**: a card's entry is found by its own edition, never by a path or a guess.
struct HistoryEntryLinkTests {
    static let edition = "mdx-sha256-v1:aa"

    static func dictionary(edition: String?, enabled: Bool = true, name: String = "Tiny") -> LibraryEntry {
        var entry = LibraryEntry(
            id: UUID(), root: StoredLocation(bookmark: Data(), path: "/tmp/Tiny"), files: [],
            languages: Languages(proposal: LanguageProposal(pair: LanguagePair(search: "en", explanation: "en"),
                                                            basis: .stated)))
        entry.edition = edition.map { Edition(rawValue: $0) }
        entry.enabled = enabled
        entry.readersName = name
        return entry
    }

    static let ref = EntryRef(edition: Edition(rawValue: edition), key: "hold", occurrence: 2)

    @Test func theRecordedEditionOpensThatExactEntry() {
        let other = Self.dictionary(edition: "mdx-sha256-v1:bb", name: "Other")
        let mine = Self.dictionary(edition: Self.edition)
        let link = HistoryEntryLink.resolve(Self.ref, in: [other, mine])
        #expect(link == .entry(ResultID(dictionary: mine.id, entry: Self.ref)))
        let visit = HistoryEntryLink.visit(opening: ResultID(dictionary: mine.id, entry: Self.ref))
        #expect(visit.result == ResultID(dictionary: mine.id, entry: Self.ref), "the entry, not the first match")
        #expect(visit.query == "hold")
    }

    @Test func aMissingOrTurnedOffEditionIsExplainedNotGuessed() {
        // Another edition of the "same" dictionary is not this reading's entry: no lineage or name guess.
        let newer = Self.dictionary(edition: "mdx-sha256-v1:cc", name: "Tiny")
        #expect(HistoryEntryLink.resolve(Self.ref, in: [newer]) == .editionMissing)
        #expect(HistoryEntryLink.resolve(Self.ref, in: []) == .editionMissing)
        let off = Self.dictionary(edition: Self.edition, enabled: false)
        #expect(HistoryEntryLink.resolve(Self.ref, in: [off]) == .dictionaryOff(name: "Tiny"))
        // A corrupt record names nothing to open.
        let blank = EntryRef(edition: Edition(rawValue: ""), key: "hold", occurrence: 0)
        #expect(HistoryEntryLink.resolve(blank, in: [Self.dictionary(edition: "")]) == .editionMissing)
        // The explicit fallback looks the recorded key up everywhere, as a word the reader typed.
        let lookUp = HistoryEntryLink.lookUp(key: "hold")
        #expect(lookUp?.scope == .all && lookUp?.result == nil && lookUp?.query == "hold")
        #expect(HistoryEntryLink.lookUp(key: "  ") == nil)
    }
}

/// **UI49**: a note is cleared deliberately, through the core's own revision, and only a note that exists.
@MainActor
struct NoteClearingTests {
    static let entry = EntryRef(edition: Edition(rawValue: "mdx-sha256-v1:aa"), key: "run", occurrence: 0)

    @Test func clearingRevisesTheExistingNoteToEmptyAndCanBeUndone() async throws {
        let existing = StudyNote(target: fakeStudyCard().target, text: "earlier", at: 1, device: "d")
        let service = FakeStudyService(notes: [existing])
        let model = StudyModelTests.model(service)
        let cleared = await model.clearNote(entry: Self.entry, name: "Tiny")
        #expect(cleared == .cleared(previous: "earlier"))
        let calls = await service.recorded()
        let sent = try #require(calls.last { if case .studyNoteAt = $0 { true } else { false } })
        guard case .studyNoteAt(let target, let text, _, _, _) = sent else { return }
        #expect(target == Self.entry && text.isEmpty)
        // The fake holds the core's write contract (`Ledger::save_note`): the clear was accepted and is what reads back.
        #expect(model.note(for: Self.entry)?.text == "", "the cleared note is what the notes say now")
        // Undo: the earlier wording saved again, as one more revision.
        guard case .saved(let earlier) = await model.saveNote(entry: Self.entry, text: "earlier", name: "Tiny") else {
            Issue.record("the earlier note was not saved")
            return
        }
        #expect(earlier.text == "earlier")
        #expect(model.note(for: Self.entry)?.text == "earlier")
        // A cleared note has nothing left to clear: no second empty revision is sent.
        _ = await model.saveNote(entry: Self.entry, text: "", name: "Tiny")
        let before = await service.recorded().count
        #expect(await model.clearNote(entry: Self.entry, name: "Tiny") == .nothingToClear)
        let after = await service.recorded()
        #expect(!after[before...].contains { if case .studyNoteAt = $0 { true } else { false } })
    }

    @Test func theCoreRefusesAFirstEmptyNoteAndWhitespace() async {
        // Mirrors `a_first_empty_note_and_whitespace_text_are_refused` in xdict-ledger: the model reports both as nil.
        let service = FakeStudyService(notes: [])
        let model = StudyModelTests.model(service)
        #expect(await model.saveNote(entry: Self.entry, text: "", name: "Tiny") == .failed, "a first note cannot be empty")
        #expect(await model.saveNote(entry: Self.entry, text: " \n", name: "Tiny") == .failed)
        if case .saved(let mine) = await model.saveNote(entry: Self.entry, text: "mine", name: "Tiny") {
            #expect(mine.text == "mine")
        } else {
            Issue.record("the note was not saved")
        }
        #expect(await model.saveNote(entry: Self.entry, text: "\t", name: "Tiny") == .failed, "whitespace is never a clear")
        #expect(model.note(for: Self.entry)?.text == "mine")
    }

    @Test func nothingToClearSendsNothingAndMakesNoReviewCard() async {
        let service = FakeStudyService(notes: [])
        let model = StudyModelTests.model(service)
        #expect(await model.clearNote(entry: Self.entry, name: "Tiny") == .nothingToClear)
        let calls = await service.recorded()
        #expect(!calls.contains { if case .studyNoteAt = $0 { true } else { false } },
                "an empty note would enrol a card the reader never asked for")
    }

    @Test func notesThatCannotBeReadAreNotMistakenForNone() async {
        let service = FailingStudyService()
        let model = StudyModel(service: service, now: { Date(timeIntervalSince1970: 1) }, device: { "d" })
        #expect(await model.loadNotes() == false, "an editor must not open empty over a note it could not read")
        #expect(await model.clearNote(entry: Self.entry, name: "Tiny") == .failed)
    }
}

actor FailingStudyService: StudyService {
    func call(_ operation: ServiceOperation) async -> ClientOutcome {
        .failure(.wire(.refused(.unsupportedOperation)))
    }
}

/// **UI47, UI50**: the review window scrolls a long note and many conflicts instead of growing past the screen, and a
/// failed read offers Try Again.
@MainActor
struct ReviewLayoutTests {
    @Test func longContentScrollsInsteadOfGrowingTheWindow() async {
        let long = String(repeating: "A long note the reader wrote about this word. ", count: 120)
        let card = fakeStudyCard(head: "g", noteText: long)
        let service = FakeStudyService(queue: [card], summary: ReviewSummary(due: 1, nextDue: nil))
        let candidates = (0..<4).map {
            ConflictCandidate(id: "c\($0)", grade: .good, at: 1_790_640_000, device: "device-\($0)",
                              after: fakeStudyCard().state)
        }
        let conflicts = (0..<12).map {
            CardConflict(target: fakeStudyCard(key: "word\($0)").target,
                         note: fakeStudyCard(key: "word\($0)").note, candidates: candidates)
        }
        await service.setConflicts(conflicts)
        let model = StudyModelTests.model(service)
        await model.refresh()
        let host = NSHostingView(rootView: ReviewView(model: model))
        let height = host.fittingSize.height
        #expect(height <= Tokens.Window.reviewMinHeight * 2,
                "\(height) pt: the content scrolls inside the window and the grades stay in reach")
    }

    @Test func aFailedReviewReadOffersRetry() {
        #expect(ReviewNotice.of(.failed, hasCard: false, hasConflicts: false) == .failed)
        #expect(ReviewNotice.failed.offersRetry)
        #expect(ReviewNotice.of(.ready, hasCard: false, hasConflicts: false) == .nothingDue)
        #expect(ReviewNotice.nothingDue.offersRetry == false)
        #expect(ReviewNotice.of(.ready, hasCard: true, hasConflicts: false) == nil)
    }
}

/// **A card's tint** (owner, 2026-10-31; supersedes UI45's neutral hairline): chosen by the card's own identity through
/// a fixed-seed hash, so it is the same on every redraw, scroll and launch; spread over the group's ten tints; and
/// always in range.
struct HistoryCardTintTests {
    static func reading(_ surface: String = "hold", entryKey: String? = nil,
                        edition: String = "mdx-sha256-v1:aa") -> LedgerReading {
        LedgerReading(surface: surface, lemma: surface, sentence: "They \(surface) that view.",
                      span: LedgerSpan(start: 5, len: UInt32(surface.utf16.count)), cut: 0, quality: "complete",
                      edition: edition, entryKey: entryKey ?? surface, occurrence: 0, dictionaryName: "Tiny",
                      language: "en", at: 1_790_641_800, device: "d")
    }

    @Test func theSameCardAlwaysTakesTheSameIndex() {
        let reading = Self.reading("hold")
        let index = HistoryCardTint.index(for: reading)
        #expect((0..<100).allSatisfy { _ in HistoryCardTint.index(for: reading) == index })
    }

    @Test func theIndexIsFixedAtLaunchNotReseededPerProcess() {
        // A golden value: `Hasher` is seeded per process, so a rule built on it would re-roll every card at launch.
        #expect(HistoryCardTint.index(for: Self.reading("hold")) == 4)
    }

    @Test func aHundredDifferentCardsSpreadOverMostOfTheTen() {
        let indices = (0..<100).map {
            HistoryCardTint.index(for: Self.reading("word\($0)", edition: "edition-\($0)"))
        }
        #expect(Set(indices).count >= 9, "\(Set(indices).count) of \(HistoryCardTint.tints.count)")
    }

    @Test func everyIndexIsInTheGroupsRange() {
        let edge = [Self.reading(""), Self.reading("😀"), Self.reading("这是一个词")]
        for reading in (0..<1_000).map({ Self.reading("word\($0)") }) + edge {
            #expect((0..<HistoryCardTint.tints.count).contains(HistoryCardTint.index(for: reading)))
        }
    }

    @Test func eachPartOfTheIdentityTakesPart() {
        let base = HistoryCardTint.index(for: Self.reading("hold"))
        #expect(HistoryCardTint.index(for: Self.reading("held", entryKey: "hold")) != base, "the word on screen")
        #expect(HistoryCardTint.index(for: Self.reading("hold", entryKey: "run")) != base, "the entry key")
        #expect(HistoryCardTint.index(for: Self.reading("hold", edition: "mdx-sha256-v1:ab")) != base, "the edition")
    }

    @Test func theTintIsTheIndexedOneOfTheGroupsTen() {
        let reading = Self.reading("hold")
        #expect(HistoryCardTint.colour(for: reading).nsColor == HistoryCardTint.tints[4].nsColor)
        #expect(Set(HistoryCardTint.tints.map(\.nsColor)).count == 10, "ten distinct system colours")
    }
}

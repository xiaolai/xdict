import Foundation
import Testing
import XDictClient
import XDictContract
import XDictUI

/// One card of the review queue, the shape the core answers.
func fakeStudyCard(key: String = "run", head: String = "", noteText: String = "my own words") -> StudyCard {
    let target = StudyTarget(lineage: "lineage", entryKey: key, occurrence: 0, kind: .entry,
                             edition: "mdx-sha256-v1:aa", definitionHash: "ab")
    let note = StudyNote(target: target, text: noteText, at: 1_790_640_000, device: "d")
    let state = StudyCardState(stability: nil, difficulty: nil, phase: .new, lastReview: nil, due: nil)
    return StudyCard(target: target, note: note, state: state, head: head, noteHead: "note-event", grades: 0)
}

/// A service that answers the study operations and records what it was asked.
actor FakeStudyService: StudyService {
    var queue: [StudyCard]
    var summary: ReviewSummary?
    var notes: [StudyNote]
    var outcomes: [StudyOutcome]
    var exported = #"{"version":1,"events":[]}"#
    var eraseReport = StudyEraseReport(clearedReadings: 2, clearedNotes: 1, clearedGrades: 3, recoverable: .freeBlocks)
    var reanchorReport = ReanchorReport(outcomes: [])
    var conflictList: [CardConflict] = []
    var syncReport = SyncReport(exported: 128, peers: 1, added: 2, skipped: 3)
    private(set) var operations: [ServiceOperation] = []

    init(queue: [StudyCard] = [], summary: ReviewSummary? = ReviewSummary(due: 0, nextDue: nil),
         notes: [StudyNote] = [], outcomes: [StudyOutcome] = []) {
        self.queue = queue
        self.summary = summary
        self.notes = notes
        self.outcomes = outcomes
    }

    func call(_ operation: ServiceOperation) async -> ClientOutcome {
        operations.append(operation)
        switch operation {
        case .reviewQueue:
            return .success(Delivered(answer: .reviewQueue(queue), payload: nil))
        case .reviewSummary:
            return .success(Delivered(answer: .reviewSummary(summary ?? ReviewSummary(due: 0, nextDue: nil)),
                                      payload: nil))
        case .reviewGrade:
            let card = queue.first ?? fakeStudyCard()
            let outcome = outcomes.isEmpty ? StudyOutcome(outcome: .recorded, card: card) : outcomes.removeFirst()
            return .success(Delivered(answer: .reviewOutcome(outcome), payload: nil))
        case .reviewUndo:
            let card = queue.first ?? fakeStudyCard()
            let outcome = outcomes.isEmpty ? StudyOutcome(outcome: .recorded, card: card) : outcomes.removeFirst()
            return .success(Delivered(answer: .reviewOutcome(outcome), payload: nil))
        case .studyNote, .studyNoteAt:
            let note = notes.first ?? StudyNote(target: fakeStudyCard().target, text: "", at: 0, device: "d")
            return .success(Delivered(answer: .studyNote(note), payload: nil))
        case .studyNotes:
            return .success(Delivered(answer: .studyNotes(notes), payload: nil))
        case .exportData:
            return .success(Delivered(answer: .exported(exported), payload: nil))
        case .eraseData:
            return .success(Delivered(answer: .erased(eraseReport), payload: nil))
        case .studyReanchor:
            return .success(Delivered(answer: .reanchored(reanchorReport), payload: nil))
        case .studyConflicts:
            return .success(Delivered(answer: .conflicts(conflictList), payload: nil))
        case .reviewResolve:
            let card = queue.first ?? fakeStudyCard()
            let outcome = outcomes.isEmpty ? StudyOutcome(outcome: .recorded, card: card) : outcomes.removeFirst()
            return .success(Delivered(answer: .reviewOutcome(outcome), payload: nil))
        case .ledgerSync:
            return .success(Delivered(answer: .synced(syncReport), payload: nil))
        default:
            return .failure(.wire(.refused(.unsupportedOperation)))
        }
    }

    func recorded() -> [ServiceOperation] { operations }

    func setReanchor(_ report: ReanchorReport) { reanchorReport = report }
    func setConflicts(_ conflicts: [CardConflict]) { conflictList = conflicts }
}

@MainActor
struct StudyModelTests {
    static let now = Date(timeIntervalSince1970: 1_790_640_000)

    static func model(_ service: FakeStudyService) -> StudyModel {
        // The instant is captured by value: a Sendable clock may not touch a main-actor static.
        let now = Self.now
        return StudyModel(service: service, now: { now }, device: { "d" })
    }

    @Test func theQueueAndTheSummaryAreLoadedAndTheShellHearsIt() async {
        let card = fakeStudyCard()
        let service = FakeStudyService(queue: [card], summary: ReviewSummary(due: 1, nextDue: 1_790_646_000))
        let model = Self.model(service)
        var heard: ReviewSummary?
        model.summaryChanged = { heard = $0 }
        await model.refresh()
        #expect(model.state == .ready)
        #expect(model.current?.target.key == card.target.key)
        #expect(model.summary == ReviewSummary(due: 1, nextDue: 1_790_646_000))
        #expect(heard == model.summary, "the reminder is planned from the summary the view shows")
    }

    @Test func aGradeLeavesTheQueueAndCarriesTheCardsHead() async throws {
        let card = fakeStudyCard(head: "grade-event")
        let service = FakeStudyService(queue: [card])
        let model = Self.model(service)
        await model.refresh()
        let outcome = await model.grade(card, .good)
        #expect(outcome?.outcome == .recorded)
        #expect(model.current == nil, "a graded card leaves the queue")
        let calls = await service.recorded()
        guard case .reviewGrade(let target, let revision, let grade, let policy, let stamp, let operation) =
            try #require(calls.last) else {
            Issue.record("not a grade call")
            return
        }
        #expect(target == card.target.key)
        #expect(revision == "grade-event", "the grade extends the head the reader saw")
        #expect(grade == .good)
        #expect(policy.retention == 0.9 && policy.maximumDays == 36_500)
        #expect(stamp.at == 1_790_640_000, "whole epoch seconds")
        #expect(stamp.device == "d")
        #expect(!operation.isEmpty)
    }

    @Test func anIneligibleGradeReloadsRatherThanEmptyingTheQueue() async {
        let card = fakeStudyCard()
        let stale = StudyOutcome(outcome: .ineligible, card: card)
        let service = FakeStudyService(queue: [card], outcomes: [stale])
        let model = Self.model(service)
        await model.refresh()
        let before = await service.recorded().count
        let outcome = await model.grade(card, .again)
        #expect(outcome?.outcome == .ineligible)
        #expect(model.current != nil, "the card was refused, not graded")
        let after = await service.recorded().count
        #expect(after > before + 1, "the queue is read again rather than guessed")
    }

    @Test func aNoteIsSavedWhereTheHistoryCardPointsAndIsFoundAgain() async throws {
        let entry = EntryRef(edition: Edition(rawValue: "mdx-sha256-v1:aa"), key: "run", occurrence: 0)
        let target = fakeStudyCard().target
        let existing = StudyNote(target: target, text: "earlier", at: 1, device: "d")
        let service = FakeStudyService(notes: [existing])
        let model = Self.model(service)
        await model.loadNotes()
        #expect(model.note(for: entry)?.text == "earlier", "the card's facts find the note without a lineage lookup")
        await model.saveNote(entry: entry, text: "new words", name: "Tiny")
        let calls = await service.recorded()
        // The note call, then the model's own reload of the notes and the queue: the note's call is the one before them.
        let sentCall = try #require(calls.last(where: { if case .studyNoteAt = $0 { return true } else { return false } }))
        guard case .studyNoteAt(let sent, let text, let name, let stamp, _) = sentCall else {
            Issue.record("not a studyNoteAt call")
            return
        }
        #expect(sent == entry)
        #expect(text == "new words")
        #expect(name == "Tiny")
        #expect(stamp.device == "d")
    }

    @Test func aJoinReanchorsTheLineagesNotesAndKeepsBothCounts() async throws {
        let target = fakeStudyCard().target
        let service = FakeStudyService()
        await service.setReanchor(ReanchorReport(outcomes: [
            ReanchorOutcome(target: target, result: .reanchored),
            ReanchorOutcome(target: target, result: .missing),
        ]))
        let model = Self.model(service)
        let old = Edition(rawValue: "mdx-sha256-v1:aa")
        let new = Edition(rawValue: "mdx-sha256-v1:bb")
        let summary = await model.reanchor(from: old, to: new)
        #expect(summary?.from == old && summary?.to == new)
        #expect(model.lastReanchor?.report.outcomes.map(\.result) == [.reanchored, .missing])
        let calls = await service.recorded()
        guard case .studyReanchor(let sentOld, let sentNew, let stamp, let prefix) = try #require(calls.first) else {
            Issue.record("not a studyReanchor call")
            return
        }
        #expect(sentOld == old && sentNew == new)
        #expect(stamp.device == "d")
        #expect(!prefix.isEmpty, "each note's event id is derived from this prefix")
    }

    /// **Two devices' answers** (ADR-0027): the queue leaves the card out, the conflict is loaded beside it, and the
    /// reader's choice is one operation whose keep travels.
    @Test func aConflictIsLoadedAndTheReadersChoiceIsOneEvent() async throws {
        let card = fakeStudyCard(head: "grade-event")
        let candidates = [
            ConflictCandidate(id: "grade-event", grade: .good, at: 1_790_640_010, device: "a", after: card.state),
            ConflictCandidate(id: "grade-event-b", grade: .again, at: 1_790_640_020, device: "b", after: card.state),
        ]
        let conflict = CardConflict(target: card.target, note: card.note, candidates: candidates)
        let service = FakeStudyService(queue: [], summary: ReviewSummary(due: 0, nextDue: nil))
        await service.setConflicts([conflict])
        let model = Self.model(service)
        await model.refresh()
        #expect(model.conflicts == [conflict])
        #expect(model.current == nil, "a conflicted card is not a card to grade")

        let outcome = await model.resolve(conflict, keep: candidates[1])
        #expect(outcome?.outcome == .recorded)
        let calls = await service.recorded()
        let sent = try #require(calls.last(where: { if case .reviewResolve = $0 { return true } else { return false } }))
        guard case .reviewResolve(let target, let keep, let stamp, let operation) = sent else {
            Issue.record("not a resolve call")
            return
        }
        #expect(target == card.target.key)
        #expect(keep == "grade-event-b", "the reader's choice names the grade that stands")
        #expect(stamp.device == "d")
        #expect(!operation.isEmpty)
    }

    @Test func aSyncPassReportsWhatItDid() async throws {
        let service = FakeStudyService()
        let model = Self.model(service)
        let report = await model.sync(input: "/tmp/xdict-sync/in", output: "/tmp/xdict-sync/out")
        #expect(report?.peers == 1 && report?.added == 2)
        #expect(model.lastSync == report)
        let calls = await service.recorded()
        guard case .ledgerSync(let input, let output, let device) = try #require(calls.first) else {
            Issue.record("not a sync call")
            return
        }
        #expect(input == "/tmp/xdict-sync/in" && output == "/tmp/xdict-sync/out")
        #expect(device == "d")
    }

    @Test func anExportIsTheCoresDocumentAndAnEraseClearsWhatItSays() async throws {
        let service = FakeStudyService(notes: [StudyNote(target: fakeStudyCard().target, text: "mine", at: 1, device: "d")])
        let model = Self.model(service)
        #expect(await model.export() == #"{"version":1,"events":[]}"#)
        let report = await model.erase()
        #expect(report?.clearedNotes == 1)
        #expect(report?.recoverable == .freeBlocks)
        #expect(model.notes.isEmpty, "nothing erased is left in the model")
        let calls = await service.recorded()
        let eraseCall = try #require(calls.last(where: { if case .eraseData = $0 { return true } else { return false } }))
        guard case .eraseData(let stamp, let operation) = eraseCall else {
            Issue.record("not an erase call")
            return
        }
        #expect(stamp.at == 1_790_640_000)
        #expect(!operation.isEmpty, "an erase is one idempotent operation")
    }
}

/// **When a reminder fires** (plan §5.4): the shell's decision from the core's summary, kept pure.
struct ReviewReminderPlanTests {
    static let now = Date(timeIntervalSince1970: 1_790_640_000)

    @Test func cardsDueNowAreRemindedAMinuteLater() {
        let reminder = ReviewReminderPlan.next(summary: ReviewSummary(due: 3, nextDue: 1_790_640_000), now: Self.now)
        #expect(reminder == ReviewReminderPlan.Reminder(fireAt: Self.now.addingTimeInterval(60), due: 3))
    }

    @Test func aFutureCardIsRemindedAtItsOwnMoment() {
        let due = Self.now.addingTimeInterval(3_600).timeIntervalSince1970
        let reminder = ReviewReminderPlan.next(summary: ReviewSummary(due: 0, nextDue: UInt64(due)), now: Self.now)
        #expect(reminder?.fireAt == Date(timeIntervalSince1970: due))
        #expect(reminder?.due == 0, "one card, not a count")
    }

    @Test func nothingScheduledIsNoReminder() {
        #expect(ReviewReminderPlan.next(summary: ReviewSummary(due: 0, nextDue: nil), now: Self.now) == nil)
    }

    @Test func aStaleDueMomentIsNeverInThePast() {
        let reminder = ReviewReminderPlan.next(summary: ReviewSummary(due: 0, nextDue: 1_000), now: Self.now)
        #expect(reminder?.fireAt == Self.now.addingTimeInterval(60))
    }
}

/// A delivery that records what would reach the system's notification centre.
actor FakeReminderDelivery: ReminderDelivery {
    var allowed: Bool
    var grants: Bool
    private(set) var scheduled: [ReviewReminderPlan.Reminder] = []
    private(set) var cancels = 0
    private(set) var asks = 0

    init(allowed: Bool = true, grants: Bool = true) {
        self.allowed = allowed
        self.grants = grants
    }

    func isAuthorized() async -> Bool { allowed }
    func requestAuthorization() async -> Bool { asks += 1; allowed = grants; return grants }
    func schedule(_ reminder: ReviewReminderPlan.Reminder) async { scheduled.append(reminder) }
    func cancel() async { cancels += 1 }
}

@MainActor
struct ReviewRemindersTests {
    static func scratch() throws -> (LearningPreferences, UserDefaults, String) {
        let name = "xdict-reminders-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (LearningPreferences(defaults: defaults), defaults, name)
    }

    static let now = Date(timeIntervalSince1970: 1_790_640_000)

    @Test func offMeansNothingIsPending() async throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let delivery = FakeReminderDelivery()
        let reminders = ReviewReminders(delivery: delivery, preferences: preferences)
        await reminders.refresh(summary: ReviewSummary(due: 2, nextDue: nil), now: Self.now)
        #expect(await delivery.scheduled.isEmpty)
        #expect(await delivery.cancels == 1, "turning it off removes what an earlier run planned")
        #expect(!reminders.isEnabled)
    }

    @Test func onAskstheSystemOnceAndPlansTheSummary() async throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let delivery = FakeReminderDelivery()
        let reminders = ReviewReminders(delivery: delivery, preferences: preferences)
        await reminders.setEnabled(true)
        #expect(await delivery.asks == 1)
        #expect(reminders.authorized)
        await reminders.refresh(summary: ReviewSummary(due: 2, nextDue: nil), now: Self.now)
        let planned = await delivery.scheduled
        #expect(planned == [ReviewReminderPlan.Reminder(fireAt: Self.now.addingTimeInterval(60), due: 2)])
        #expect(preferences.remindersEnabled, "the switch survives a relaunch")
    }

    @Test func aRefusalIsSaidNotSwallowed() async throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let delivery = FakeReminderDelivery(grants: false)
        let reminders = ReviewReminders(delivery: delivery, preferences: preferences)
        await reminders.setEnabled(true)
        #expect(!reminders.authorized)
        #expect(reminders.refused, "the settings row says macOS is not allowing it")
        await reminders.refresh(summary: ReviewSummary(due: 2, nextDue: nil), now: Self.now)
        #expect(await delivery.scheduled.isEmpty)
    }

    @Test func nothingDueRemovesThePendingReminder() async throws {
        let (preferences, defaults, name) = try Self.scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        preferences.remindersEnabled = true
        let delivery = FakeReminderDelivery()
        let reminders = ReviewReminders(delivery: delivery, preferences: preferences)
        await reminders.refresh(summary: ReviewSummary(due: 0, nextDue: nil), now: Self.now)
        #expect(await delivery.scheduled.isEmpty)
        #expect(await delivery.cancels == 1)
    }
}

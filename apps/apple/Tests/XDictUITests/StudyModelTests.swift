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
    /// Answered first, one a call, before `reanchorReport`: a sweep's successive calls.
    var reanchorReports: [ReanchorReport] = []
    var conflictList: [CardConflict] = []
    var syncReport = SyncReport(exported: 128, peers: 1, added: 2, skipped: 3)
    /// When set, grades and undos get no answer, as a dropped connection or a deadline leaves them.
    var unanswered = false
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
        case .reviewGrade where unanswered, .reviewUndo where unanswered:
            return .failure(.wire(.interrupted))
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
        case .studyNote(_, let entry, let text, _, _, _), .studyNoteAt(let entry, let text, _, _, _):
            return write(entry: entry, text: text)
        case .studyNotes:
            return .success(Delivered(answer: .studyNotes(notes), payload: nil))
        case .exportData:
            return .success(Delivered(answer: .exported(exported), payload: nil))
        case .eraseData:
            return .success(Delivered(answer: .erased(eraseReport), payload: nil))
        case .studyReanchor:
            let report = reanchorReports.isEmpty ? reanchorReport : reanchorReports.removeFirst()
            return .success(Delivered(answer: .reanchored(report), payload: nil))
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

    /// **The core's note-write contract** (`Ledger::save_note`): whitespace-only text is refused; exactly empty text is a
    /// revision of an existing note (a clear) and refused as a first note; anything else saves or revises the note.
    private func write(entry: EntryRef, text: String) -> ClientOutcome {
        let index = notes.firstIndex {
            $0.target.edition == entry.edition.rawValue && $0.target.entryKey == entry.key
                && $0.target.occurrence == entry.occurrence
        }
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if blank && (!text.isEmpty || index == nil) {
            return .failure(.wire(.refused(.unsupportedOperation)))
        }
        let target = index.map { notes[$0].target }
            ?? StudyTarget(lineage: "lineage", entryKey: entry.key, occurrence: entry.occurrence, kind: .entry,
                           edition: entry.edition.rawValue, definitionHash: "ab")
        let note = StudyNote(target: target, text: text, at: 1_790_640_000, device: "d")
        if let index { notes[index] = note } else { notes.append(note) }
        return .success(Delivered(answer: .studyNote(note), payload: nil))
    }

    func setUnanswered(_ value: Bool) { unanswered = value }
    func setReanchor(_ report: ReanchorReport) { reanchorReport = report }
    func setReanchors(_ reports: [ReanchorReport]) { reanchorReports = reports }
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

    /// **Undo takes back the grade just made** (audit 2026-11-05, H2): after grading "run" the card in front is "walk",
    /// and Undo must void run's new grade event — never walk's earlier one — and put run back in front.
    @Test func undoVoidsTheGradeJustMadeNotTheCardInFront() async throws {
        let run = fakeStudyCard(key: "run", head: "run-earlier")
        let walk = fakeStudyCard(key: "walk", head: "walk-earlier")
        let service = FakeStudyService(queue: [run, walk], outcomes: [
            StudyOutcome(outcome: .recorded, card: fakeStudyCard(key: "run", head: "run-graded")),
            StudyOutcome(outcome: .recorded, card: run),
        ])
        let model = Self.model(service)
        await model.refresh()
        #expect(!model.canUndo, "nothing graded in this session: Undo has nothing to take back")
        #expect(await model.undo() == nil)
        await model.grade(run, .good)
        #expect(model.current?.target.key == walk.target.key)
        #expect(model.canUndo)
        let outcome = await model.undo()
        #expect(outcome?.outcome == .recorded)
        let calls = await service.recorded()
        let sent = try #require(calls.last(where: { if case .reviewUndo = $0 { return true } else { return false } }))
        guard case .reviewUndo(let target, let event, _, _) = sent else {
            Issue.record("not an undo call")
            return
        }
        #expect(target == run.target.key, "the graded card, not the one in front")
        #expect(event == "run-graded", "the event the grade wrote, as its outcome reported it")
        #expect(model.queue.map(\.target.entryKey) == ["run", "walk"], "the undone card is in front again")
        #expect(!model.canUndo, "one grade, one undo")
    }

    /// **A grade that got no answer is not a grade** (audit 2026-11-05, M6): the card stays in front, the failure is
    /// said, and the next answer that arrives clears it.
    @Test func anUnansweredGradeKeepsTheCardAndSaysSo() async {
        let card = fakeStudyCard(head: "grade-event")
        let service = FakeStudyService(queue: [card, fakeStudyCard(key: "walk")])
        await service.setUnanswered(true)
        let model = Self.model(service)
        await model.refresh()
        let before = model.queue
        #expect(await model.grade(card, .good) == nil)
        #expect(model.queue == before, "the reader's answer was not recorded, so the card is still to be answered")
        #expect(model.failure == .grade)
        #expect(!model.canUndo, "nothing was written, so nothing can be undone")
        await service.setUnanswered(false)
        #expect(await model.grade(card, .good)?.outcome == .recorded)
        #expect(model.failure == nil)
        #expect(model.current?.target.entryKey == "walk")
    }

    /// An undo that got no answer keeps the grade it would take back, so Undo can be pressed again.
    @Test func anUnansweredUndoCanBeAskedAgain() async {
        let card = fakeStudyCard(head: "grade-event")
        let service = FakeStudyService(queue: [card], outcomes: [
            StudyOutcome(outcome: .recorded, card: fakeStudyCard(head: "graded")),
        ])
        let model = Self.model(service)
        await model.refresh()
        await model.grade(card, .hard)
        await service.setUnanswered(true)
        #expect(await model.undo() == nil)
        #expect(model.failure == .undo)
        #expect(model.canUndo)
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
        guard case .studyReanchor(let sentOld, let sentNew, let stamp, let prefix, _) = try #require(calls.first) else {
            Issue.record("not a studyReanchor call")
            return
        }
        #expect(sentOld == old && sentNew == new)
        #expect(stamp.device == "d")
        #expect(!prefix.isEmpty, "each note's event id is derived from this prefix")
    }

    /// **A sweep runs until no note remains** (audit 2026-11-05, M5): the core answers "more remain" once, so the model
    /// calls again from that cursor with the same prefix, and the summary holds both calls' outcomes — a `failed` note
    /// counted, never dropped.
    @Test func aReanchorThatLeavesNotesCallsAgainFromItsCursorAndCountsFailures() async throws {
        let target = fakeStudyCard().target
        let service = FakeStudyService()
        await service.setReanchors([
            ReanchorReport(outcomes: [ReanchorOutcome(target: target, result: .reanchored)], next: "cursor-1"),
            ReanchorReport(outcomes: [ReanchorOutcome(target: target, result: .failed(detail: "Malformed"))]),
        ])
        let model = Self.model(service)
        let summary = try #require(await model.reanchor(from: Edition(rawValue: "mdx-sha256-v1:aa"),
                                                        to: Edition(rawValue: "mdx-sha256-v1:bb")))
        #expect(summary.report.outcomes.map(\.result) == [.reanchored, .failed(detail: "Malformed")])
        #expect(summary.failed == 1)
        #expect(!summary.unfinished)
        let sent = await service.recorded().compactMap { operation -> (String, String?)? in
            guard case .studyReanchor(_, _, _, let prefix, let after) = operation else { return nil }
            return (prefix, after)
        }
        #expect(sent.map(\.1) == [nil, "cursor-1"], "the second call starts where the first stopped")
        #expect(Set(sent.map(\.0)).count == 1, "one sweep, one prefix: a retried note is the same event")
    }

    /// **A cursor that does not advance ends the sweep** rather than looping, and the summary says it did not finish.
    @Test func aReanchorWhoseCursorDoesNotAdvanceStopsUnfinished() async throws {
        let service = FakeStudyService()
        await service.setReanchor(ReanchorReport(outcomes: [], next: "stuck"))
        let model = Self.model(service)
        let summary = try #require(await model.reanchor(from: Edition(rawValue: "mdx-sha256-v1:aa"),
                                                        to: Edition(rawValue: "mdx-sha256-v1:bb")))
        #expect(summary.unfinished)
        let calls = await service.recorded().filter { if case .studyReanchor = $0 { true } else { false } }
        #expect(calls.count == 2, "the first call and the one that answered the same cursor")
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

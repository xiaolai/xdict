import Foundation
import Observation
import XDictClient
import XDictContract

/// What the review surface needs of the service: one call. The real client is `ServiceClient`; a test supplies its own.
public protocol StudyService: Sendable {
    func call(_ operation: ServiceOperation) async -> ClientOutcome
}

extension ServiceClient: StudyService {}

/// **The review session's state** (plan-history-and-learning §5): the due queue, the summary, a grade, an undo and a
/// note. The core owns eligibility, scheduling and identity; the model only carries the reader's answers and the one
/// stamp they are made at.
@MainActor
@Observable
public final class StudyModel {
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed
    }

    public private(set) var state: State = .idle
    public private(set) var queue: [StudyCard] = []
    public private(set) var summary: ReviewSummary?
    /// The reader's scheduling settings; the weights stay the build's until a calibrated profile exists.
    public var policy: StudyPolicy
    /// The most recent grade or undo, so the view can say what happened rather than guess.
    public private(set) var lastOutcome: StudyOutcome?
    /// **The grade Undo takes back** (audit 2026-11-05, H2): the card as the grade the reader made last in this session
    /// left it, its head that grade's own event. Undo used to read the card in front, which after a grade is the *next*
    /// card: it voided that card's earlier grade and left the one just made. Nil when there is nothing to take back.
    public private(set) var lastGraded: StudyCard?
    /// **What the reader asked for and did not get** (audit 2026-11-05, M6): a grade or an undo the service did not
    /// answer. The card stays where it was, so the answer can be given again; the next answer that arrives clears it.
    public private(set) var failure: Failure?

    /// A grade or an undo that got no answer.
    public enum Failure: Equatable, Sendable {
        case grade
        case undo
    }

    /// Whether Undo has a grade of this session to take back.
    public var canUndo: Bool { lastGraded != nil }
    /// The reader's notes, loaded on demand: an editor revises what is there rather than starting over.
    public private(set) var notes: [StudyNote] = []
    /// **The cards two devices left conflicted** (ADR-0027): they are not in the queue, and the reader settles each.
    public private(set) var conflicts: [CardConflict] = []
    /// What the last sync pass did, and whether one is under way.
    public private(set) var lastSync: SyncReport?
    public private(set) var syncing = false
    /// **What the last join did to the notes** (plan §5.1): which edition they left and which they moved to, so the
    /// reader is told where a note went and where one could not follow. Nil until a join happens.
    public private(set) var lastReanchor: ReanchorSummary?

    /// A join's two editions, and what the core found for each note: every call's outcomes, and in `report.next`
    /// where the sweep stopped when it did not reach the end.
    public struct ReanchorSummary: Equatable, Sendable {
        public let from: Edition
        public let to: Edition
        public let report: ReanchorReport

        public init(from: Edition, to: Edition, report: ReanchorReport) {
            self.from = from
            self.to = to
            self.report = report
        }

        /// Notes the core could not classify (audit 2026-11-05, M5): they stay on the old edition.
        public var failed: Int {
            report.outcomes.count { if case .failed = $0.result { true } else { false } }
        }

        /// The sweep stopped before the last note: a call failed, or the ceiling on calls was reached.
        public var unfinished: Bool { report.next != nil }
    }

    /// **The most calls one join's re-anchor makes** (audit 2026-11-05, M5): each call does a bounded amount and names
    /// where the next starts, so the sweep is a loop; the ceiling keeps a core that never finishes from looping forever.
    /// At the core's 128 renders a call, it covers thousands of notes.
    public static let reanchorCallLimit = 64

    /// Called after every load of the summary, so the shell can plan its reminder (§5.4) without the view knowing it.
    @ObservationIgnored public var summaryChanged: (@MainActor (ReviewSummary?) -> Void)?
    /// What the review window opens the card's entry through (UI48): the shell's library and main window, wired by the
    /// app. Nil offers no Open Entry.
    @ObservationIgnored public var entryLinks: HistoryEntryLinks?
    /// **An erase took every reading, note and grade** (ADR-0037): the app-session answer memory goes with them, since
    /// each answer is about a reading the ledger no longer holds.
    @ObservationIgnored public var onErased: (@MainActor () -> Void)?

    @ObservationIgnored private let service: any StudyService
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let device: @Sendable () -> String
    @ObservationIgnored private var generation = 0

    public init(service: any StudyService, policy: StudyPolicy = StudyPolicy(retention: 0.9, maximumDays: 36_500),
                now: @escaping @Sendable () -> Date = { Date() },
                device: @escaping @Sendable () -> String = { DeviceIdentity.current() }) {
        self.service = service
        self.policy = policy
        self.now = now
        self.device = device
    }

    /// The card in front: the queue's first, or nil when nothing is due.
    public var current: StudyCard? { queue.first }

    /// A stamp for this moment: whole epoch seconds, as every ledger instant is.
    public var stamp: StudyStamp {
        StudyStamp(at: now().timeIntervalSince1970.rounded(.down), device: device())
    }

    /// Loads the due queue and the summary.
    public func refresh() async {
        generation += 1
        let mine = generation
        // A reload behind a shown card keeps showing it: the spinner is for a window with nothing in it yet.
        if state != .ready { state = .loading }
        let at = stamp.at
        let queued = await service.call(.reviewQueue(now: at, limit: 100))
        let summarized = await service.call(.reviewSummary(now: at))
        let disputed = await service.call(.studyConflicts)
        guard mine == generation else { return }
        guard case .success(let cards) = queued, case .reviewQueue(let list) = cards.answer,
              case .success(let report) = summarized, case .reviewSummary(let summary) = report.answer else {
            state = .failed
            return
        }
        if case .success(let delivered) = disputed, case .conflicts(let found) = delivered.answer {
            conflicts = found
        }
        queue = list
        self.summary = summary
        state = .ready
        summaryChanged?(summary)
    }

    /// **Keeps one branch of a conflict** (ADR-0027): the other answers are voided by replay, never retracted silently.
    @discardableResult
    public func resolve(_ conflict: CardConflict, keep candidate: ConflictCandidate) async -> StudyOutcome? {
        let result = await service.call(.reviewResolve(target: conflict.target.key, keep: candidate.id, stamp: stamp,
                                                       operation: UUID().uuidString))
        guard case .success(let delivered) = result, case .reviewOutcome(let outcome) = delivered.answer else {
            return nil
        }
        lastOutcome = outcome
        await refresh()
        return outcome
    }

    /// **One sync pass** (plan §2.6): every peer's log in `input` merges in, then this device's is written to `output`.
    /// The two are the app group's folders; the app moves the reader's folder in and out around this call.
    @discardableResult
    public func sync(input: String, output: String) async -> SyncReport? {
        syncing = true
        defer { syncing = false }
        let result = await service.call(.ledgerSync(input: input, output: output, device: device()))
        guard case .success(let delivered) = result, case .synced(let report) = delivered.answer else { return nil }
        lastSync = report
        await refresh()
        return report
    }

    /// **Grades the card in front** (plan §5.3): the revision is the card's head, so a grade of a card that moved is
    /// answered `ineligible` and nothing is written. **Only an answer the service gave moves the card** (audit
    /// 2026-11-05, M6): a call that failed, timed out or was superseded leaves it in front and says so, where it used to
    /// drop it as if graded until the next refresh.
    @discardableResult
    public func grade(_ card: StudyCard, _ grade: StudyGrade) async -> StudyOutcome? {
        guard let outcome = await graded(card, grade) else {
            failure = .grade
            return nil
        }
        failure = nil
        lastOutcome = outcome
        // The event the grade wrote is the head of the card it reports; a grade that wrote nothing has none to void.
        lastGraded = Self.wrote(outcome) ? outcome.card : nil
        if outcome.outcome == .ineligible {
            await refresh()
        } else {
            queue.removeAll { $0.target.key == card.target.key }
        }
        return outcome
    }

    /// **Voids the grade made last in this session** (H2): that card and that grade's event, whatever card is in front
    /// now. The card returns to the front of the queue, to be answered again.
    @discardableResult
    public func undo() async -> StudyOutcome? {
        guard let card = lastGraded else { return nil }
        let result = await service.call(.reviewUndo(target: card.target.key, gradeEvent: card.head,
                                                    stamp: stamp, operation: UUID().uuidString))
        guard case .success(let delivered) = result, case .reviewOutcome(let outcome) = delivered.answer else {
            failure = .undo
            return nil
        }
        failure = nil
        lastOutcome = outcome
        // Answered either way: undone, or refused because the card moved since, which no retry changes.
        lastGraded = nil
        await refresh()
        if Self.wrote(outcome) {
            queue.removeAll { $0.target.key == outcome.card.target.key }
            queue.insert(outcome.card, at: 0)
        }
        return outcome
    }

    /// Whether the ledger holds the event an answer reports: written now, earlier (a retried operation), or written
    /// and not yet flushed.
    private static func wrote(_ outcome: StudyOutcome) -> Bool {
        switch outcome.outcome {
        case .recorded, .duplicate, .uncertain: !outcome.card.head.isEmpty
        case .skippedLanguage, .ineligible: false
        }
    }

    /// **What saving a note did** (audit rounds 1–4, 2026-10-26): whether it was written, needed the reader's answer
    /// because a note is already there, or failed.
    public enum NoteSave: Equatable, Sendable {
        case saved(StudyNote)
        case needsReplacement
        case failed
    }

    /// The entries whose save is in flight. **A second save waits for the first**, because its own check would read the
    /// notes as they were before that write and replace it silently.
    private var savingNotes: Set<String> = []

    /// **Saves the reader's note** on an entry named by the history card's facts; the core hashes the definition and
    /// resolves the lineage. **The check and the write are one operation** (audit rounds 1–4, 2026-10-26): the pane used
    /// to ask whether a note was there, and one saved in the meantime was replaced without the question.
    @discardableResult
    public func saveNote(entry: EntryRef, text: String, name: String, replacing: Bool = true) async -> NoteSave {
        let key = "\(entry.edition.rawValue)\u{0}\(entry.key)\u{0}\(entry.occurrence)"
        guard !savingNotes.contains(key) else { return .failed }
        savingNotes.insert(key)
        defer { savingNotes.remove(key) }
        if !replacing {
            _ = await loadNotes()
            if note(for: entry) != nil { return .needsReplacement }
        }
        let result = await service.call(.studyNoteAt(entry: entry, text: text, name: name, stamp: stamp,
                                                     operation: UUID().uuidString))
        guard case .success(let delivered) = result, case .studyNote(let note) = delivered.answer else { return .failed }
        await loadNotes()
        await refresh()
        return .saved(note)
    }

    /// The note a target already has, for an editor that revises rather than starts over.
    public func note(for target: StudyTarget) async -> StudyNote? {
        await loadNotes()
        return notes.first { $0.target.key == target.key }
    }

    /// **The note on an entry the history card names** (plan §5.1): edition, key and occurrence — the identity a reading
    /// carries. A reading records facts, so the note is found without asking the core for the lineage first.
    public func note(for entry: EntryRef) -> StudyNote? {
        notes.first {
            $0.target.edition == entry.edition.rawValue && $0.target.entryKey == entry.key
                && $0.target.occurrence == entry.occurrence
        }
    }

    /// **Moves the notes of an edition to the one the reader joined it to** (plan §5.1): the core matches key and
    /// definition hash and leaves a note where it is when the definition changed, moved or is gone — never binding
    /// another record silently. **Until no note remains** (audit 2026-11-05, M5): a call does a bounded amount, so the
    /// sweep calls again from the cursor each report names, up to `reanchorCallLimit` calls; a cursor that does not
    /// advance, or a call that fails after the first, ends it with `unfinished` set.
    @discardableResult
    public func reanchor(from old: Edition, to new: Edition) async -> ReanchorSummary? {
        let prefix = UUID().uuidString
        var outcomes: [ReanchorOutcome] = []
        var after: String?
        var remaining: String?
        for call in 0..<Self.reanchorCallLimit {
            let result = await service.call(.studyReanchor(oldEdition: old, newEdition: new, stamp: stamp,
                                                           operationPrefix: prefix, after: after))
            guard case .success(let delivered) = result, case .reanchored(let report) = delivered.answer else {
                guard call > 0 else {
                    lastReanchor = nil
                    return nil
                }
                remaining = after
                break
            }
            outcomes += report.outcomes
            remaining = report.next
            guard let next = report.next, next != after else { break }
            after = next
        }
        let summary = ReanchorSummary(from: old, to: new, report: ReanchorReport(outcomes: outcomes, next: remaining))
        lastReanchor = summary
        await loadNotes()
        await refresh()
        return summary
    }

    /// **The reader's data as one versioned JSON document** (plan §5.5): every event the ledger holds — a reading's
    /// sentence included — and no dictionary's text. The shell writes it where the reader chooses.
    public func export() async -> String? {
        let result = await service.call(.exportData)
        guard case .success(let delivered) = result, case .exported(let json) = delivered.answer else { return nil }
        return json
    }

    /// **Erases what the ledger holds** and answers what may remain recoverable (ADR-0024): the shell words that answer,
    /// never more than the receipt says. The queue is reloaded, so a review window open beside it empties.
    @discardableResult
    public func erase() async -> StudyEraseReport? {
        let result = await service.call(.eraseData(stamp: stamp, operation: UUID().uuidString))
        guard case .success(let delivered) = result, case .erased(let report) = delivered.answer else { return nil }
        notes = []
        lastGraded = nil
        onErased?()
        await refresh()
        return report
    }

    /// Loads every note the ledger holds; an editor opened from a card uses it to fill in what is already written.
    /// **False when they could not be read** (UI49, UI50): an editor must not open empty over a note it could not read,
    /// where saving would replace the reader's words without their knowing.
    @discardableResult
    public func loadNotes() async -> Bool {
        let result = await service.call(.studyNotes)
        guard case .success(let delivered) = result, case .studyNotes(let loaded) = delivered.answer else { return false }
        notes = loaded
        return true
    }

    /// What clearing a note did.
    public enum NoteClearing: Equatable, Sendable {
        /// The note's text was revised to empty; `previous` is what Undo saves back.
        case cleared(previous: String)
        /// There was no note with words to clear: nothing was sent, so no review card was made.
        case nothingToClear
        /// The notes could not be read, or the revision was refused: nothing is known to have changed.
        case failed
    }

    /// **Clears a note's words, deliberately** (UI49). The core has no note deletion (its ledger records a note saved or
    /// revised, never withdrawn); `Ledger::save_note` accepts exactly empty text only as a revision of a note the target
    /// already has, and refuses a first empty note and whitespace. So this is that revision: the word stays enrolled in
    /// Review, and the earlier wording stays in the ledger's events — the export — until the reader erases their data.
    /// The editor's confirmation says exactly that. Only a note with words is revised, so a clear is never sent for a
    /// target the core would refuse.
    public func clearNote(entry: EntryRef, name: String) async -> NoteClearing {
        guard await loadNotes() else { return .failed }
        guard let existing = note(for: entry), !existing.text.isEmpty else { return .nothingToClear }
        guard case .saved = await saveNote(entry: entry, text: "", name: name) else { return .failed }
        return .cleared(previous: existing.text)
    }

    private func graded(_ card: StudyCard, _ grade: StudyGrade) async -> StudyOutcome? {
        let result = await service.call(.reviewGrade(target: card.target.key, revision: card.head, grade: grade,
                                                     policy: policy, stamp: stamp,
                                                     operation: UUID().uuidString))
        guard case .success(let delivered) = result, case .reviewOutcome(let outcome) = delivered.answer else {
            return nil
        }
        return outcome
    }
}

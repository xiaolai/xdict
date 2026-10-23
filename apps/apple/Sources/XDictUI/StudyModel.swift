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

    /// A join's two editions, and what the core found for each note.
    public struct ReanchorSummary: Equatable, Sendable {
        public let from: Edition
        public let to: Edition
        public let report: ReanchorReport

        public init(from: Edition, to: Edition, report: ReanchorReport) {
            self.from = from
            self.to = to
            self.report = report
        }
    }

    /// Called after every load of the summary, so the shell can plan its reminder (§5.4) without the view knowing it.
    @ObservationIgnored public var summaryChanged: (@MainActor (ReviewSummary?) -> Void)?
    /// What the review window opens the card's entry through (UI48): the shell's library and main window, wired by the
    /// app. Nil offers no Open Entry.
    @ObservationIgnored public var entryLinks: HistoryEntryLinks?

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
    /// answered `ineligible` and nothing is written.
    @discardableResult
    public func grade(_ card: StudyCard, _ grade: StudyGrade) async -> StudyOutcome? {
        let outcome = await graded(card, grade)
        lastOutcome = outcome
        if outcome?.outcome == .ineligible {
            await refresh()
        } else {
            queue.removeAll { $0.target.key == card.target.key }
        }
        return outcome
    }

    /// Voids the card's latest grade, while the card is still in the state that grade produced.
    @discardableResult
    public func undo(_ card: StudyCard) async -> StudyOutcome? {
        guard !card.head.isEmpty else { return nil }
        let result = await service.call(.reviewUndo(target: card.target.key, gradeEvent: card.head,
                                                    stamp: stamp, operation: UUID().uuidString))
        guard case .success(let delivered) = result, case .reviewOutcome(let outcome) = delivered.answer else {
            return nil
        }
        lastOutcome = outcome
        await refresh()
        return outcome
    }

    /// **Saves the reader's note** on an entry named by the history card's facts; the core hashes the definition and
    /// resolves the lineage.
    @discardableResult
    public func saveNote(entry: EntryRef, text: String, name: String) async -> StudyNote? {
        let result = await service.call(.studyNoteAt(entry: entry, text: text, name: name, stamp: stamp,
                                                     operation: UUID().uuidString))
        guard case .success(let delivered) = result, case .studyNote(let note) = delivered.answer else { return nil }
        await loadNotes()
        await refresh()
        return note
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
    /// another record silently.
    @discardableResult
    public func reanchor(from old: Edition, to new: Edition) async -> ReanchorSummary? {
        let result = await service.call(.studyReanchor(oldEdition: old, newEdition: new, stamp: stamp,
                                                       operationPrefix: UUID().uuidString))
        guard case .success(let delivered) = result, case .reanchored(let report) = delivered.answer else {
            lastReanchor = nil
            return nil
        }
        let summary = ReanchorSummary(from: old, to: new, report: report)
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
        guard await saveNote(entry: entry, text: "", name: name) != nil else { return .failed }
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

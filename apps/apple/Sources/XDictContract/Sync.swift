import Foundation

/// **Sync and its conflicts, in the contract's types** (plan-history-and-learning §2.6, ADR-0027): a grade a device made
/// from a revision another device also graded, the card they left in two states, and what one pass over the reader's
/// folder did. What travels is the log — readings, notes and evidence hashes — never a dictionary's text.

/// One candidate of a conflict: what a device answered, and the state it would leave the card in.
public struct ConflictCandidate: Codable, Hashable, Sendable {
    /// The grade event's id: what a resolution keeps.
    public let id: String
    public let grade: StudyGrade
    public let at: Double
    public let device: String
    public let after: StudyCardState

    public init(id: String, grade: StudyGrade, at: Double, device: String, after: StudyCardState) {
        self.id = id
        self.grade = grade
        self.at = at
        self.device = device
        self.after = after
    }
}

/// **A card two devices' answers left in two states**: the reader keeps one candidate, and that choice is an event.
public struct CardConflict: Codable, Hashable, Sendable {
    public let target: StudyTarget
    public let note: StudyNote
    /// Oldest first: the reader reads the story in order.
    public let candidates: [ConflictCandidate]

    public init(target: StudyTarget, note: StudyNote, candidates: [ConflictCandidate]) {
        self.target = target
        self.note = note
        self.candidates = candidates
    }
}

/// What one sync pass did with the reader's folder.
public struct SyncReport: Codable, Hashable, Sendable {
    /// This device's log file's size, as written for the other devices.
    public let exported: UInt64
    /// The peer logs it read.
    public let peers: UInt64
    /// The events the peers had that this log did not.
    public let added: UInt64
    /// The events both already had.
    public let skipped: UInt64

    public init(exported: UInt64, peers: UInt64, added: UInt64, skipped: UInt64) {
        self.exported = exported
        self.peers = peers
        self.added = added
        self.skipped = skipped
    }
}

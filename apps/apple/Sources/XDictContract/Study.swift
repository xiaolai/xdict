import Foundation

/// **Study, in the contract's types** (plan-history-and-learning §5): a note's target and evidence, a card's state, the
/// scheduler configuration a grade was made under, and the review queue's answer. The core owns every rule — identity,
/// eligibility, scheduling and replay — so a shell carries the values and draws them.

/// When and by which device a study event happened.
public struct StudyStamp: Codable, Hashable, Sendable {
    public let at: Double
    public let device: String

    public init(at: Double, device: String) {
        self.at = at
        self.device = device
    }
}

/// **The reader's scheduling settings for a grade**: the retention and the interval cap. The weights stay the build's
/// (the scheduler's defaults) until a calibrated profile exists.
public struct StudyPolicy: Codable, Hashable, Sendable {
    public let retention: Double
    public let maximumDays: Int64

    public init(retention: Double, maximumDays: Int64) {
        self.retention = retention
        self.maximumDays = maximumDays
    }
}

/// The reader's answer to a card; the raw values are the scheduler's ratings.
public enum StudyGrade: UInt8, Codable, Hashable, Sendable, CaseIterable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
}

/// The stage the scheduler put a card in.
public enum StudyPhase: String, Codable, Hashable, Sendable {
    case new, learning, review, relearning
}

/// A card's state as the scheduler left it: what the next grade and the queue read.
public struct StudyCardState: Codable, Hashable, Sendable {
    public let stability: Double?
    public let difficulty: Double?
    public let phase: StudyPhase
    public let lastReview: Double?
    public let due: Double?

    public init(stability: Double?, difficulty: Double?, phase: StudyPhase, lastReview: Double?, due: Double?) {
        self.stability = stability
        self.difficulty = difficulty
        self.phase = phase
        self.lastReview = lastReview
        self.due = due
    }

    public var isNew: Bool { phase == .new }
}

/// A target's kind; v1 has entry-level targets, and the tagged enum leaves a sense kind as an addition.
public enum StudyTargetKind: String, Codable, Hashable, Sendable {
    case entry
}

/// **What a note is about** (ADR-0025, plan §5.1): the lineage the ledger owns, the entry's key and occurrence, and
/// evidence — the edition and a hash of the definition, never the definition's text.
public struct StudyTarget: Codable, Hashable, Sendable {
    public let lineage: String
    public let entryKey: String
    public let occurrence: UInt32
    public let kind: StudyTargetKind
    public let edition: String
    public let definitionHash: String

    public init(lineage: String, entryKey: String, occurrence: UInt32, kind: StudyTargetKind, edition: String,
                definitionHash: String) {
        self.lineage = lineage
        self.entryKey = entryKey
        self.occurrence = occurrence
        self.kind = kind
        self.edition = edition
        self.definitionHash = definitionHash
    }

    /// The identity the review calls name: everything but the evidence.
    public var key: String {
        "\(lineage)\u{1f}\(entryKey)\u{1f}\(occurrence)\u{1f}\(kind.rawValue)"
    }
}

/// **The reader's own words about an entry**: the note travels, and carries no dictionary content.
public struct StudyNote: Codable, Hashable, Sendable {
    public let target: StudyTarget
    public let text: String
    public let at: Double
    public let device: String

    public init(target: StudyTarget, text: String, at: Double, device: String) {
        self.target = target
        self.text = text
        self.at = at
        self.device = device
    }
}

/// **One card the review queue shows**: the target with its current evidence, the note, and the state a grade extends.
public struct StudyCard: Codable, Hashable, Sendable {
    public let target: StudyTarget
    public let note: StudyNote
    public let state: StudyCardState
    /// The head event a grade extends: the latest non-void grade's id, empty for a new card.
    public let head: String
    /// The note event's own id: a revision names it as its parent.
    public let noteHead: String
    /// How many grades of this card are not voided.
    public let grades: UInt64

    public init(target: StudyTarget, note: StudyNote, state: StudyCardState, head: String, noteHead: String,
                grades: UInt64) {
        self.target = target
        self.note = note
        self.state = state
        self.head = head
        self.noteHead = noteHead
        self.grades = grades
    }
}

/// What the reader has to do now, and when the next card falls due.
public struct ReviewSummary: Codable, Hashable, Sendable {
    public let due: UInt64
    public let nextDue: UInt64?

    public init(due: UInt64, nextDue: UInt64?) {
        self.due = due
        self.nextDue = nextDue
    }
}

/// What a grade or an undo did to a card, and the card as it now stands.
public struct StudyOutcome: Codable, Hashable, Sendable {
    public let outcome: LedgerRecordOutcome
    public let card: StudyCard

    public init(outcome: LedgerRecordOutcome, card: StudyCard) {
        self.outcome = outcome
        self.card = card
    }
}

/// What a re-anchor attempt found for one note (plan §5.1).
public enum ReanchorResult: String, Codable, Hashable, Sendable {
    /// The same occurrence in the new edition holds the same definition: the note moved.
    case reanchored
    /// The same definition moved to another occurrence: the note is left where it is.
    case reordered
    /// The occurrence holds a different definition: the note is left where it is.
    case changed
    /// The new edition has no record under this key: the note is left where it is.
    case missing
}

public struct ReanchorOutcome: Codable, Hashable, Sendable {
    public let target: StudyTarget
    public let result: ReanchorResult

    public init(target: StudyTarget, result: ReanchorResult) {
        self.target = target
        self.result = result
    }
}

public struct ReanchorReport: Codable, Hashable, Sendable {
    public let outcomes: [ReanchorOutcome]

    public init(outcomes: [ReanchorOutcome]) {
        self.outcomes = outcomes
    }
}

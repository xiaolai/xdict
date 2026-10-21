import Foundation

/// **The reading history, in the contract's types** (ADR-0023, ADR-0024): one reading as the core records it, and the
/// days the drawer shows. The core owns every rule — the language filter, the collapse of repeats, the calendar day in
/// the reader's zone — so a shell only carries the values and draws them.

/// A range of the sentence, in UTF-16 code units: the unit the capture contract uses.
public struct LedgerSpan: Codable, Hashable, Sendable {
    public let start: UInt32
    public let len: UInt32

    public init(start: UInt32, len: UInt32) {
        self.start = start
        self.len = len
    }
}

/// **One reading**: the word, the sentence and where the word sits in it, the capture's own doubts, the dictionary by
/// its **edition** hash (content identity, never the reader's lineage: ADR-0025), and the moment.
public struct LedgerReading: Codable, Hashable, Sendable {
    /// The word exactly as it was on screen.
    public let surface: String
    /// The dictionary's form where it is known; the surface otherwise.
    public let lemma: String
    /// The sentence the capture validated. It is here because the reader asked for the history (ADR-0023); the core
    /// writes it only when the history is on, and never for a language outside the reader's targets.
    public let sentence: String
    public let span: LedgerSpan?
    /// Which ends of the sentence the capture may have cut: bit 0 the start, bit 1 the end.
    public let cut: UInt8
    /// The capture's quality word (`complete`, `mayBeCut`, `missing`); empty when unknown.
    public let quality: String
    /// The dictionary's edition hash.
    public let edition: String
    public let entryKey: String
    public let occurrence: UInt32
    /// The dictionary's name at the time; a reading outlives a rename.
    public let dictionaryName: String
    /// The dictionary's declared search-side language; empty when none is declared.
    public let language: String
    /// Whole epoch seconds.
    public let at: Double
    /// Which device recorded it (the lineage mints per device).
    public let device: String

    public init(surface: String, lemma: String, sentence: String, span: LedgerSpan?, cut: UInt8, quality: String,
                edition: String, entryKey: String, occurrence: UInt32, dictionaryName: String, language: String,
                at: Double, device: String) {
        self.surface = surface
        self.lemma = lemma
        self.sentence = sentence
        self.span = span
        self.cut = cut
        self.quality = quality
        self.edition = edition
        self.entryKey = entryKey
        self.occurrence = occurrence
        self.dictionaryName = dictionaryName
        self.language = language
        self.at = at
        self.device = device
    }
}

/// What a record call did (ADR-0024): an uncertain commit is answered as such, and a retry with the same operation id
/// settles it to one event.
public enum LedgerRecordOutcome: String, Codable, Hashable, Sendable {
    case recorded
    case duplicate
    /// The append happened, its durability did not: a retry with the same operation id settles it.
    case uncertain
    /// A reading outside the reader's target languages: nothing was written, the sentence included.
    case skippedLanguage
    /// The card was not in the state the caller saw, or was not due: nothing was written (plan §5.3).
    case ineligible
}

/// One card: a reading, how many times it was met that day, and the reading events it is made of — the ids a removal
/// names.
public struct LedgerCard: Codable, Hashable, Sendable {
    public let reading: LedgerReading
    public let times: UInt32
    public let events: [String]

    public init(reading: LedgerReading, times: UInt32, events: [String]) {
        self.reading = reading
        self.times = times
        self.events = events
    }
}

/// How a day is named; the shell words it in the reader's language.
public enum LedgerDayLabel: String, Codable, Hashable, Sendable {
    case today, yesterday, weekday, date
}

/// One calendar day of readings, newest card first, in the reader's own zone.
public struct LedgerDay: Codable, Hashable, Sendable {
    /// `yyyy-MM-dd` in the reader's zone: stable across relaunches.
    public let id: String
    /// The day's start, as whole epoch seconds.
    public let start: Double
    public let label: LedgerDayLabel
    public let cards: [LedgerCard]

    public init(id: String, start: Double, label: LedgerDayLabel, cards: [LedgerCard]) {
        self.id = id
        self.start = start
        self.label = label
        self.cards = cards
    }
}

/// The drawer's days, newest first: at most the core's bound of days and cards.
public struct LedgerHistory: Codable, Hashable, Sendable {
    public let days: [LedgerDay]

    public init(days: [LedgerDay]) {
        self.days = days
    }
}

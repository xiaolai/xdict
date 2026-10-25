/// **What the shell asks, as values** (`conformance/ai/CONTRACT.md` §2; ADR-0021): the captured word and its sentence,
/// the entry's whole text when the reader allows it to be sent, and the language the explanation is written in. The core
/// never sees any of it.
public struct AIEntryRef: Sendable, Equatable {
    public let edition: String
    public let key: String
    public let occurrence: UInt32

    public init(edition: String, key: String, occurrence: UInt32) {
        self.edition = edition
        self.key = key
        self.occurrence = occurrence
    }
}

/// The entry as `entry_text` returned it: whole text, its cut report, and the reference it belongs to (ADR-0021 d.5).
public struct AIEntryText: Sendable, Equatable {
    public let text: String
    public let complete: Bool
    public let cutAt: UInt64
    public let ref: AIEntryRef

    public init(text: String, complete: Bool, cutAt: UInt64, ref: AIEntryRef) {
        self.text = text
        self.complete = complete
        self.cutAt = cutAt
        self.ref = ref
    }
}

/// The word's span in the sentence, in UTF-16 units, or the fact that the capture had none (`CONTRACT.md` §2).
public enum AITermRange: Sendable, Equatable {
    case notFound
    case range(start: Int, length: Int)
}

public enum AIMode: String, Sendable, Equatable, CaseIterable {
    /// The entry and the sentence; the model chooses a sense (ADR-0021).
    case grounded
    /// The sentence alone (ADR-0021 d.4).
    case sentenceOnly
    /// **The reader names the sense, and the model explains that sense** (ADR-0029): the whole entry is sent, the
    /// chosen sense is carried as a value, and the answer says whether it fits. Never a sentence-only fallback.
    case explainSense
}

/// **The sense the reader is reading** (ADR-0029 d.2): the core's ordinal and canonical range in `entry.text`, the
/// exact text of that range, the label as printed, its section, and whether the whole sense was sent.
public struct AISense: Sendable, Equatable {
    public let id: UInt32
    public let start: UInt64
    public let len: UInt64
    public let text: String
    public let label: String?
    public let section: String?
    public let whole: Bool

    public init(id: UInt32, start: UInt64, len: UInt64, text: String, label: String?, section: String?,
                whole: Bool) {
        self.id = id
        self.start = start
        self.len = len
        self.text = text
        self.label = label
        self.section = section
        self.whole = whole
    }
}

public struct AIQuestion: Sendable, Equatable {
    public let term: String
    public let termRange: AITermRange
    public let sentence: String
    /// Nil in `sentenceOnly` mode; present in `grounded` and `explainSense` mode (`CONTRACT.md` §2).
    public let entry: AIEntryText?
    /// **The chosen sense**, in `explainSense` mode only (`CONTRACT.md` §2; ADR-0029 d.6): an input, never a result.
    public let sense: AISense?
    /// A BCP 47 tag (`CONTRACT.md` §2).
    public let language: String
    public let mode: AIMode
    /// **The dictionary's spelling of the phrase a phrase ask is about** (contract 5, `CONTRACT.md` §2), slots and all —
    /// `take something into account`, where `term` is the sentence's own words. The lookup key and provenance; the
    /// composer never substitutes it, and it never enters the composed question. Nil for a word ask.
    public let phrase: String?

    public init(term: String, termRange: AITermRange, sentence: String, entry: AIEntryText?, sense: AISense? = nil,
                language: String, mode: AIMode, phrase: String? = nil) {
        self.term = term
        self.termRange = termRange
        self.sentence = sentence
        self.entry = entry
        self.sense = sense
        self.language = language
        self.mode = mode
        self.phrase = phrase
    }
}

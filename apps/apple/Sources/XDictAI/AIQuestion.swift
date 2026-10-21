import Foundation

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

public enum AIMode: String, Sendable, Equatable {
    case grounded
    case sentenceOnly
}

public struct AIQuestion: Sendable, Equatable {
    public let term: String
    public let termRange: AITermRange
    public let sentence: String
    /// Nil in `sentenceOnly` mode; present in `grounded` mode (`CONTRACT.md` §2).
    public let entry: AIEntryText?
    /// A BCP 47 tag (`CONTRACT.md` §2).
    public let language: String
    public let mode: AIMode

    public init(term: String, termRange: AITermRange, sentence: String, entry: AIEntryText?, language: String,
                mode: AIMode) {
        self.term = term
        self.termRange = termRange
        self.sentence = sentence
        self.entry = entry
        self.language = language
        self.mode = mode
    }
}

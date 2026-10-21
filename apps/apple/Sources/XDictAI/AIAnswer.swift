import Foundation

/// The eight outcomes the contract names (`CONTRACT.md` §5).
public enum AIOutcome: String, Sendable, Equatable, CaseIterable {
    case matched
    case ambiguous
    case noMatchingSense
    case insufficientContext
    case incompleteInput
    case explanationOnly
    case refused
    case guardrail
}

public struct AIAnswer: Sendable, Equatable {
    public let outcome: AIOutcome
    public let quotes: [String]
    public let explanation: String

    public init(outcome: AIOutcome, quotes: [String], explanation: String) {
        self.outcome = outcome
        self.quotes = quotes
        self.explanation = explanation
    }
}

/// Why an answer was refused; the code is the contract's stable name (`CONTRACT.md` §5).
public enum AIAnswerError: Error, Equatable, Sendable {
    case shape
    case outcome
    case quoteNotFound
    case quoteCount
    case quoteTooLong
    case explanation
    case noMatchingSenseOnPartial
    case ungrounded

    public var code: String {
        switch self {
        case .shape: "answer.shape"
        case .outcome: "answer.outcome"
        case .quoteNotFound: "answer.quote.notFound"
        case .quoteCount: "answer.quote.count"
        case .quoteTooLong: "answer.quote.tooLong"
        case .explanation: "answer.explanation"
        case .noMatchingSenseOnPartial: "answer.noMatchingSenseOnPartial"
        case .ungrounded: "answer.ungrounded"
        }
    }
}

/// **The model's answer, checked mechanically** (`CONTRACT.md` §5). An invalid answer is a typed failure, never repaired
/// into a plausible one; a quote that is not in the text that was sent is never presented as grounded.
public enum AIAnswerValidator {
    /// A quote over this many UTF-8 bytes is refused.
    public static let quoteCeilingUTF8 = 800
    /// An explanation outside 1…this many UTF-8 bytes is refused.
    public static let explanationCeilingUTF8 = 600

    /// **The quote must be a byte substring of the text that was sent** (`CONTRACT.md` §5): Swift's `String.contains`
    /// compares canonically, so an NFD quote would pass against an NFC entry; the check is on UTF-8 bytes, as the
    /// contract says. (Audit finding, 2026-10-20.)
    static func contains(_ needle: String, in haystack: String) -> Bool {
        let n = Array(needle.utf8)
        let h = Array(haystack.utf8)
        guard !n.isEmpty else { return true }
        guard n.count <= h.count else { return false }
        for start in 0...(h.count - n.count) where h[start..<(start + n.count)].elementsEqual(n) {
            return true
        }
        return false
    }

    /// The answer in `json`, checked against the question it answers: the mode, and the entry text as sent (nil in
    /// `sentenceOnly` mode).
    public static func validate(json: Data, mode: AIMode, entry: AIEntryText?) throws(AIAnswerError) -> AIAnswer {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { throw .shape }
        let keys = Set(object.keys)
        guard keys == ["outcome", "quotes", "explanation"] else { throw .shape }
        guard let outcomeText = object["outcome"] as? String, let outcome = AIOutcome(rawValue: outcomeText) else {
            throw .outcome
        }
        guard let quotes = object["quotes"] as? [String], let explanation = object["explanation"] as? String else {
            throw .shape
        }

        switch mode {
        case .sentenceOnly:
            // A quoted answer cannot be grounded without an entry; it is shown as ungrounded, never as grounded.
            guard quotes.isEmpty else { throw .ungrounded }
        case .grounded:
            guard outcome != .explanationOnly else { throw .outcome }
            guard let entry else { throw .shape }
            for quote in quotes {
                guard quote.utf8.count <= quoteCeilingUTF8 else { throw .quoteTooLong }
                guard Self.contains(quote, in: entry.text) else { throw .quoteNotFound }
            }
        }

        switch outcome {
        case .matched: guard quotes.count == 1 else { throw .quoteCount }
        case .ambiguous: guard (2...3).contains(quotes.count) else { throw .quoteCount }
        default: guard quotes.isEmpty else { throw .quoteCount }
        }

        if mode == .grounded, let entry, !entry.complete, outcome == .noMatchingSense {
            throw .noMatchingSenseOnPartial
        }
        guard !explanation.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
            throw .explanation
        }
        let bytes = explanation.utf8.count
        guard bytes >= 1, bytes <= explanationCeilingUTF8 else { throw .explanation }
        return AIAnswer(outcome: outcome, quotes: quotes, explanation: explanation)
    }
}

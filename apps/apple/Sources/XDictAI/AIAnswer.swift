import Foundation

/// The outcomes the contract names (`CONTRACT.md` §5; contract 3 adds the chosen-sense verdicts).
public enum AIOutcome: String, Sendable, Equatable, CaseIterable {
    /// The selection modes: the model chose a sense.
    case matched
    case ambiguous
    case noMatchingSense
    case insufficientContext
    case incompleteInput
    case explanationOnly
    case refused
    case guardrail
    /// **The chosen-sense mode**: the sense the reader named fits the sentence.
    case explained
    /// **The chosen-sense mode**: the sense the reader named does not fit — never a silent switch.
    case doesNotFit
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
    /// An empty quote is not a quotation (it passed `contains("")` before contract 3).
    case quoteEmpty
    /// The chosen sense was not sent whole, so neither verdict may be given (`CONTRACT.md` §5, ADR-0029 d.7).
    case partialTarget

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
        case .quoteEmpty: "answer.quote.empty"
        case .partialTarget: "answer.partialTarget"
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
        // **An empty needle is in every text, and an empty quote is not a quotation**: contract 3 refuses it before
        // this check, and this stays false so a later path cannot reintroduce the pass.
        guard !n.isEmpty else { return false }
        guard n.count <= h.count else { return false }
        for start in 0...(h.count - n.count) where h[start..<(start + n.count)].elementsEqual(n) {
            return true
        }
        return false
    }

    /// The answer in `json`, checked against the question it answers: the mode, the entry text as sent (nil in
    /// `sentenceOnly` mode), and — in `explainSense` mode — the chosen sense (`CONTRACT.md` §5; ADR-0029 d.7).
    public static func validate(json: Data, mode: AIMode, entry: AIEntryText?, sense: AISense? = nil)
        throws(AIAnswerError) -> AIAnswer {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { throw .shape }
        let keys = Set(object.keys)
        guard keys == ["outcome", "quotes", "explanation"] else { throw .shape }
        guard let outcomeText = object["outcome"] as? String, let outcome = AIOutcome(rawValue: outcomeText) else {
            throw .outcome
        }
        guard let quotes = object["quotes"] as? [String], let explanation = object["explanation"] as? String else {
            throw .shape
        }
        // **An empty quote is not a quotation**, in every mode (contract 3): it used to pass `contains("")`.
        for quote in quotes where quote.isEmpty {
            throw .quoteEmpty
        }

        switch mode {
        case .sentenceOnly:
            // A quoted answer cannot be grounded without an entry; it is shown as ungrounded, never as grounded.
            guard quotes.isEmpty else { throw .ungrounded }
            guard outcome != .explained, outcome != .doesNotFit else { throw .outcome }
        case .grounded:
            guard outcome != .explanationOnly, outcome != .explained, outcome != .doesNotFit else { throw .outcome }
            guard let entry else { throw .shape }
            for quote in quotes {
                guard quote.utf8.count <= quoteCeilingUTF8 else { throw .quoteTooLong }
                guard Self.contains(quote, in: entry.text) else { throw .quoteNotFound }
            }
        case .explainSense:
            // The verdict is the chosen sense's: the selection outcomes are not answers to this question.
            guard [.explained, .doesNotFit, .insufficientContext, .incompleteInput, .refused, .guardrail]
                .contains(outcome) else { throw .outcome }
            guard let sense else { throw .shape }
            for quote in quotes {
                guard quote.utf8.count <= quoteCeilingUTF8 else { throw .quoteTooLong }
                // **A quote must lie inside the chosen sense**, not merely inside the entry (ADR-0029 d.7).
                guard Self.contains(quote, in: sense.text) else { throw .quoteNotFound }
            }
            // **No verdict from a partial target**: the missing part of the sense may decide it.
            guard sense.whole || (outcome != .explained && outcome != .doesNotFit) else { throw .partialTarget }
        }

        switch outcome {
        case .matched: guard quotes.count == 1 else { throw .quoteCount }
        case .ambiguous: guard (2...3).contains(quotes.count) else { throw .quoteCount }
        case .explained: guard quotes.count <= 2 else { throw .quoteCount }
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

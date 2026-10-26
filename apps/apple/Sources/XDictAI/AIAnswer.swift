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
    /// **The translation mode**: the sentence stands in the asked language (contract 6 §5b).
    case translated
}

public struct AIAnswer: Sendable, Equatable {
    public let outcome: AIOutcome
    public let quotes: [String]
    public let explanation: String
    /// **The translation mode's own text** (contract 6 §5b): set exactly when the mode is `translate`, and nil in
    /// every other mode, whose answer has no `translation` field at all.
    public let translation: String?

    public init(outcome: AIOutcome, quotes: [String], explanation: String, translation: String? = nil) {
        self.outcome = outcome
        self.quotes = quotes
        self.explanation = explanation
        self.translation = translation
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
    /// **The translation mode's text is not one paragraph in the asked language's shape** (contract 6 §5b).
    case translation

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
        case .translation: "answer.translation"
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
    /// **A translation's own bound** (contract 6 §5b): one paragraph, 1…this many UTF-8 bytes.
    public static let translationCeilingUTF8 = 2_000
    /// **The grammar mode's explanation bound** (contract 6 §5c): a paragraph about structure fits where the meaning
    /// modes' one sentence does not.
    public static let grammarCeilingUTF8 = 1_200

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
        // **Contract 6's two operations answer in their own shapes** (§5b, §5c): neither quotes anything, so neither
        // can be validated by the meaning modes' rules.
        switch mode {
        case .translate: return try translationAnswer(object)
        case .explainGrammar: return try grammarAnswer(object)
        case .grounded, .sentenceOnly, .explainSense: break
        }
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
            guard outcome != .explained, outcome != .doesNotFit, outcome != .translated else { throw .outcome }
        case .grounded:
            guard outcome != .explanationOnly, outcome != .explained, outcome != .doesNotFit,
                  outcome != .translated else { throw .outcome }
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
        case .translate, .explainGrammar:
            // **Contract 6's answers were validated above** and returned; reaching this line with one of their modes is a
            // harness fault, and it fails as a shape refusal rather than being read by another mode's rules.
            throw .shape
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
        guard oneLine(explanation, ceiling: explanationCeilingUTF8) else { throw .explanation }
        return AIAnswer(outcome: outcome, quotes: quotes, explanation: explanation)
    }

    /// **A translation answer, checked mechanically** (contract 6 §5b): exactly three fields; the translation is one
    /// paragraph in the asked language, and only a refusal or a guardrail explains itself.
    private static func translationAnswer(_ object: [String: Any]) throws(AIAnswerError) -> AIAnswer {
        guard Set(object.keys) == ["outcome", "translation", "explanation"] else { throw .shape }
        guard let text = object["outcome"] as? String, let outcome = AIOutcome(rawValue: text) else { throw .outcome }
        guard let translation = object["translation"] as? String,
              let explanation = object["explanation"] as? String else { throw .shape }
        switch outcome {
        case .translated:
            guard oneLine(translation, ceiling: translationCeilingUTF8) else { throw .translation }
            guard explanation.isEmpty else { throw .explanation }
        case .refused, .guardrail:
            guard translation.isEmpty else { throw .translation }
            guard oneLine(explanation, ceiling: explanationCeilingUTF8) else { throw .explanation }
        default:
            throw .outcome
        }
        return AIAnswer(outcome: outcome, quotes: [], explanation: explanation, translation: translation)
    }

    /// **A grammar answer, checked mechanically** (contract 6 §5c): exactly two fields, and the explanation is one
    /// paragraph in every outcome — a refusal says why in the same field the analysis uses.
    private static func grammarAnswer(_ object: [String: Any]) throws(AIAnswerError) -> AIAnswer {
        guard Set(object.keys) == ["outcome", "explanation"] else { throw .shape }
        guard let text = object["outcome"] as? String, let outcome = AIOutcome(rawValue: text) else { throw .outcome }
        guard [.explained, .insufficientContext, .refused, .guardrail].contains(outcome) else { throw .outcome }
        guard let explanation = object["explanation"] as? String else { throw .shape }
        guard oneLine(explanation, ceiling: grammarCeilingUTF8) else { throw .explanation }
        return AIAnswer(outcome: outcome, quotes: [], explanation: explanation)
    }

    /// **One paragraph, within its bound**: no line break of any kind (U+2028 and U+2029 draw a line too), and
    /// 1…`ceiling` UTF-8 bytes.
    static func oneLine(_ text: String, ceiling: Int) -> Bool {
        guard !text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else { return false }
        let bytes = text.utf8.count
        return bytes >= 1 && bytes <= ceiling
    }
}

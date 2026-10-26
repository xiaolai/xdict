import Foundation
import FoundationModels

/// The contract's outcomes as a guided type: the model may generate only these (`CONTRACT.md` §5). The two
/// chosen-sense verdicts are generatable here and refused by the validator outside `explainSense` (contract 3).
@Generable
enum AppleAnswerOutcome: String, CaseIterable {
    case matched
    case ambiguous
    case noMatchingSense
    case insufficientContext
    case incompleteInput
    case explanationOnly
    case refused
    case guardrail
    case explained
    case doesNotFit
}

/// **The contract's answer, generated into fields** (ADR-0021 d.2): the sense quoted from the entry, one sentence, and
/// one of the ten outcomes. The validator, not the model, decides whether the quote is in the text that was sent.
@Generable
struct AppleAnswer {
    @Guide(description: "One of the contract's outcomes: matched, ambiguous, noMatchingSense, insufficientContext, incompleteInput, explanationOnly, refused, guardrail, explained, doesNotFit.")
    let outcome: AppleAnswerOutcome
    @Guide(description: "Exact text copied character for character from the entry: one quote for matched, two or three for ambiguous, up to two for explained (each from the reader's chosen sense), none for any other outcome.")
    let quotes: [String]
    @Guide(description: "One sentence without a line break.")
    let explanation: String
}

/// **The translation's own answer, as a guided type** (contract 6, §5b): the sentence in the asked language, and a reason
/// only when the model refused. Its own type because guided generation constrains the fields it is given, and a
/// translation has no `quotes` at all.
@Generable
enum AppleTranslationOutcome: String, CaseIterable {
    case translated
    case refused
    case guardrail
}

@Generable
struct AppleTranslationAnswer {
    @Guide(description: "One of the translation's outcomes: translated, refused, guardrail.")
    let outcome: AppleTranslationOutcome
    @Guide(description: "The sentence translated into the reader's language: one paragraph, no line break, no notes and no alternatives. Empty when the outcome is refused or guardrail.")
    let translation: String
    @Guide(description: "Empty when the outcome is translated; otherwise one sentence without a line break saying why.")
    let explanation: String
}

/// **The grammar's own answer, as a guided type** (contract 6, §5c): one paragraph about the sentence's structure.
@Generable
enum AppleGrammarOutcome: String, CaseIterable {
    case explained
    case insufficientContext
    case refused
    case guardrail
}

@Generable
struct AppleGrammarAnswer {
    @Guide(description: "One of the grammar's outcomes: explained, insufficientContext, refused, guardrail.")
    let outcome: AppleGrammarOutcome
    @Guide(description: "How the sentence's grammar works — its clauses, what each phrase does, and the part the reader was looking at — in one paragraph without a line break.")
    let explanation: String
}

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

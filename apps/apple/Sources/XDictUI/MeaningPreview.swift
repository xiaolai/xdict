import Foundation
import XDictAI

/// **The prompt as the reader will see it** (plan-ai-meaning WI-6; ADR-0021 d.13): Settings composes a sample question
/// through the same `AIComposer` the session uses, so the preview is the composer's own bytes; the answer pane shows the
/// bytes that really went (`MeaningSent`). A sample is labelled as one: it is not the reader's entry.
public enum MeaningPreview {
    public static let term = "hold"
    /// Built from `term`, so the sample is about the word it shows; not a sentence the app localizes.
    public static let sentence = "They \(term) that view about the quiet river."
    /// A small stand-in entry: a headword, two senses, enough to show what "the whole entry" looks like in a request.
    public static let entry = "hold\n  1. to keep; to have or maintain\n  2. to contain"

    /// The sample question the preview composes, in `language` and `mode`.
    public static func question(language: String, mode: AIMode) -> AIQuestion {
        let sample = AIEntryText(text: Self.entry, complete: true, cutAt: 0,
                                 ref: AIEntryRef(edition: "sample", key: Self.term, occurrence: 0))
        return AIQuestion(term: Self.term, termRange: .range(start: 5, length: 4), sentence: Self.sentence,
                          entry: mode == .grounded ? sample : nil, language: language, mode: mode)
    }

    /// The composed request, byte for byte what the transport would send for this template; a broken template is its
    /// typed refusal, which the pane shows in red rather than sending.
    public static func compose(template: String, language: String, mode: AIMode) -> Result<String, AIComposeError> {
        do {
            return .success(try AIComposer.compose(template: template, question: question(language: language, mode: mode)))
        } catch {
            return .failure(error)
        }
    }
}

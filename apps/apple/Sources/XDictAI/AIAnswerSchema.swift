/// **The answer's shape, as the contract states it** (`CONTRACT.md` §5, §5b, §5c): the JSON schema handed to the Claude
/// CLI's `--json-schema`. It is XDict's contract, not the provider's — sayso receives it as configuration, because the
/// library does not know what an answer means. **One schema per question shape** (contract 6): a translation's answer
/// has `translation` and no `quotes`, and a grammar answer has neither, so a single union schema would either forbid
/// what a translate question returns or accept a meaning answer with the wrong fields. `AIContractTests` holds every
/// outcome the contract names to these strings, so a new verdict cannot be added to one and forgotten in the other.
public enum AIAnswerSchema {
    /// The meaning modes: `grounded`, `sentenceOnly`, `explainSense`.
    public static let claude = #"{"type":"object","properties":{"outcome":{"type":"string","enum":["matched","ambiguous","noMatchingSense","insufficientContext","incompleteInput","explanationOnly","refused","guardrail","explained","doesNotFit"]},"quotes":{"type":"array","items":{"type":"string"},"maxItems":3},"explanation":{"type":"string"}},"required":["outcome","quotes","explanation"],"additionalProperties":false}"#

    /// The translation mode (`CONTRACT.md` §5b): the sentence in the asked language, and a reason only when refused.
    public static let translation = #"{"type":"object","properties":{"outcome":{"type":"string","enum":["translated","refused","guardrail"]},"translation":{"type":"string"},"explanation":{"type":"string"}},"required":["outcome","translation","explanation"],"additionalProperties":false}"#

    /// The grammar mode (`CONTRACT.md` §5c): the analysis in one field, in every outcome.
    public static let grammar = #"{"type":"object","properties":{"outcome":{"type":"string","enum":["explained","insufficientContext","refused","guardrail"]},"explanation":{"type":"string"}},"required":["outcome","explanation"],"additionalProperties":false}"#

    /// The schema a question of `mode` answers in.
    public static func claude(for mode: AIMode) -> String {
        switch mode {
        case .translate: translation
        case .explainGrammar: grammar
        case .grounded, .sentenceOnly, .explainSense: claude
        }
    }
}

/// **The answer's shape, as the contract states it** (`CONTRACT.md` §5): the JSON schema handed to the Claude CLI's
/// `--json-schema`. It is XDict's contract, not the provider's — sayso receives it as configuration, because the
/// library does not know what an answer means. `AIContractTests` holds every outcome the contract names to this
/// string, so a new verdict cannot be added to one and forgotten in the other.
public enum AIAnswerSchema {
    public static let claude = #"{"type":"object","properties":{"outcome":{"type":"string","enum":["matched","ambiguous","noMatchingSense","insufficientContext","incompleteInput","explanationOnly","refused","guardrail","explained","doesNotFit"]},"quotes":{"type":"array","items":{"type":"string"},"maxItems":3},"explanation":{"type":"string"}},"required":["outcome","quotes","explanation"],"additionalProperties":false}"#
}

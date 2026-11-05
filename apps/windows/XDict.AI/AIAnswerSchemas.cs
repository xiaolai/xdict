// The answer schema per question shape (ai-contract §5, §5b, §5c): the Claude CLI's `--json-schema` and the
// Codex CLI's schema file. One schema per shape, never a union that accepts a translation's fields for a meaning.
namespace XDict.AI;

public static class AIAnswerSchemas
{
    public const string Meaning =
        "{\"type\":\"object\",\"properties\":{\"outcome\":{\"type\":\"string\",\"enum\":[\"matched\",\"ambiguous\",\"noMatchingSense\",\"insufficientContext\",\"incompleteInput\",\"explanationOnly\",\"refused\",\"guardrail\"]},\"quotes\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"maxItems\":3},\"explanation\":{\"type\":\"string\"}},\"required\":[\"outcome\",\"quotes\",\"explanation\"],\"additionalProperties\":false}";

    public const string Translation =
        "{\"type\":\"object\",\"properties\":{\"outcome\":{\"type\":\"string\",\"enum\":[\"translated\",\"refused\",\"guardrail\"]},\"translation\":{\"type\":\"string\"},\"explanation\":{\"type\":\"string\"}},\"required\":[\"outcome\",\"translation\",\"explanation\"],\"additionalProperties\":false}";

    public const string Grammar =
        "{\"type\":\"object\",\"properties\":{\"outcome\":{\"type\":\"string\",\"enum\":[\"explained\",\"insufficientContext\",\"refused\",\"guardrail\"]},\"explanation\":{\"type\":\"string\"}},\"required\":[\"outcome\",\"explanation\"],\"additionalProperties\":false}";

    public static string For(AIMode mode) => mode switch
    {
        AIMode.Translate => Translation,
        AIMode.ExplainGrammar => Grammar,
        _ => Meaning,
    };
}

// §5–§5c's mechanical answer validation: the exact shape per mode, the outcome's set, a quote that is a byte-exact
// substring of the text it answers, the counts, the partial-target rules, and the explanation and translation bounds.
using System.Text;
using System.Text.Json;

namespace XDict.AI;

public sealed record AIValidationResult(string Status, string? Outcome, string? Translation, string? Explanation,
    string? Code)
{
    public static AIValidationResult Ok(string outcome, string? translation = null, string? explanation = null) =>
        new("ok", outcome, translation, explanation, null);
    public static AIValidationResult Invalid(string code) => new("invalid", null, null, null, code);
}

public static class AIValidator
{
    private const int MaxQuoteBytes = 800;
    private const int MaxExplanationBytes = 600;
    private const int MaxGrammarBytes = 1_200;
    private const int MaxTranslationBytes = 2_000;

    private static readonly HashSet<string> Grounded =
        ["matched", "ambiguous", "noMatchingSense", "insufficientContext", "incompleteInput", "refused", "guardrail"];
    private static readonly HashSet<string> SentenceOnly =
        ["explanationOnly", "insufficientContext", "incompleteInput", "refused", "guardrail"];
    private static readonly HashSet<string> ExplainSense =
        ["explained", "doesNotFit", "insufficientContext", "incompleteInput", "refused", "guardrail"];
    private static readonly HashSet<string> Translate = ["translated", "refused", "guardrail"];
    private static readonly HashSet<string> Grammar = ["explained", "insufficientContext", "refused", "guardrail"];

    public static AIValidationResult Validate(JsonElement input)
    {
        AIMode mode = AIModes.Parse(input.GetProperty("mode").GetString()!);
        AIEntryText? entry = AIEntryText.Read(input);
        AISense? sense = AISense.Read(input);
        if (!input.TryGetProperty("answer", out JsonElement answer) || answer.ValueKind != JsonValueKind.Object)
            return AIValidationResult.Invalid("answer.shape");
        return mode switch
        {
            AIMode.Translate => TranslationAnswer(answer),
            AIMode.ExplainGrammar => GrammarAnswer(answer),
            _ => MeaningAnswer(answer, mode, entry, sense),
        };
    }

    private static AIValidationResult MeaningAnswer(JsonElement answer, AIMode mode, AIEntryText? entry, AISense? sense)
    {
        if (!Exactly(answer, "outcome", "quotes", "explanation")) return AIValidationResult.Invalid("answer.shape");
        if (!TryString(answer, "outcome", out string? outcome) ||
            !TryString(answer, "explanation", out string? explanation) ||
            !answer.TryGetProperty("quotes", out JsonElement quotes) || quotes.ValueKind != JsonValueKind.Array)
            return AIValidationResult.Invalid("answer.shape");
        var quoteList = new List<string>();
        foreach (JsonElement quote in quotes.EnumerateArray())
        {
            if (quote.ValueKind != JsonValueKind.String) return AIValidationResult.Invalid("answer.shape");
            quoteList.Add(quote.GetString()!);
        }
        if (quoteList.Any(string.IsNullOrEmpty)) return AIValidationResult.Invalid("answer.quote.empty");

        // Sentence-only mode: any quote at all is ungrounded, whatever the outcome claims (contract §5 rule 7).
        if (mode == AIMode.SentenceOnly && quoteList.Count > 0)
            return AIValidationResult.Invalid("answer.ungrounded");

        HashSet<string> allowed = mode switch
        {
            AIMode.Grounded => Grounded,
            AIMode.SentenceOnly => SentenceOnly,
            _ => ExplainSense,
        };
        if (!allowed.Contains(outcome!)) return AIValidationResult.Invalid("answer.outcome");

        if (mode == AIMode.Grounded && entry is { Complete: false } && outcome == "noMatchingSense")
            return AIValidationResult.Invalid("answer.noMatchingSenseOnPartial");
        if (mode == AIMode.ExplainSense && sense is { Whole: false } &&
            outcome is "explained" or "doesNotFit")
            return AIValidationResult.Invalid("answer.partialTarget");

        string? target = mode switch
        {
            AIMode.Grounded => entry?.Text,
            AIMode.ExplainSense => sense?.Text,
            _ => null,
        };
        foreach (string quote in quoteList)
        {
            if (Encoding.UTF8.GetByteCount(quote) > MaxQuoteBytes)
                return AIValidationResult.Invalid("answer.quote.tooLong");
            if (target is not null && !target.Contains(quote, StringComparison.Ordinal))
                return AIValidationResult.Invalid("answer.quote.notFound");
        }

        int expected = outcome switch
        {
            "matched" => quoteList.Count == 1 ? 1 : 0,
            "ambiguous" => quoteList.Count is 2 or 3 ? 1 : 0,
            "explained" => quoteList.Count <= 2 ? 1 : 0,
            _ => quoteList.Count == 0 ? 1 : 0,
        };
        if (expected == 0) return AIValidationResult.Invalid("answer.quote.count");

        if (!Explanation(explanation!, MaxExplanationBytes, allowEmpty: false))
            return AIValidationResult.Invalid("answer.explanation");
        return AIValidationResult.Ok(outcome!, explanation: explanation);
    }

    private static AIValidationResult TranslationAnswer(JsonElement answer)
    {
        if (!Exactly(answer, "outcome", "translation", "explanation"))
            return AIValidationResult.Invalid("answer.shape");
        if (!TryString(answer, "outcome", out string? outcome) ||
            !TryString(answer, "translation", out string? translation) ||
            !TryString(answer, "explanation", out string? explanation))
            return AIValidationResult.Invalid("answer.shape");
        if (!Translate.Contains(outcome!)) return AIValidationResult.Invalid("answer.outcome");
        if (outcome == "translated")
        {
            if (!Explanation(translation!, MaxTranslationBytes, allowEmpty: false))
                return AIValidationResult.Invalid("answer.translation");
            if (explanation!.Length != 0) return AIValidationResult.Invalid("answer.explanation");
        }
        else
        {
            if (translation!.Length != 0) return AIValidationResult.Invalid("answer.translation");
            if (!Explanation(explanation!, MaxExplanationBytes, allowEmpty: false))
                return AIValidationResult.Invalid("answer.explanation");
        }
        return AIValidationResult.Ok(outcome!, translation, explanation);
    }

    private static AIValidationResult GrammarAnswer(JsonElement answer)
    {
        if (!Exactly(answer, "outcome", "explanation")) return AIValidationResult.Invalid("answer.shape");
        if (!TryString(answer, "outcome", out string? outcome) ||
            !TryString(answer, "explanation", out string? explanation))
            return AIValidationResult.Invalid("answer.shape");
        if (!Grammar.Contains(outcome!)) return AIValidationResult.Invalid("answer.outcome");
        if (!Explanation(explanation!, MaxGrammarBytes, allowEmpty: false))
            return AIValidationResult.Invalid("answer.explanation");
        return AIValidationResult.Ok(outcome!, explanation: explanation);
    }

    private static bool Explanation(string text, int max, bool allowEmpty)
    {
        if (text.Length == 0) return allowEmpty;
        if (text.Contains('\n') || text.Contains('\r')) return false;
        int bytes = Encoding.UTF8.GetByteCount(text);
        return bytes >= 1 && bytes <= max;
    }

    private static bool Exactly(JsonElement answer, params string[] names)
    {
        int count = 0;
        foreach (JsonProperty property in answer.EnumerateObject())
        {
            if (!names.Contains(property.Name, StringComparer.Ordinal)) return false;
            count++;
        }
        return count == names.Length;
    }

    private static bool TryString(JsonElement answer, string name, out string? text)
    {
        text = null;
        if (!answer.TryGetProperty(name, out JsonElement value) || value.ValueKind != JsonValueKind.String)
            return false;
        text = value.GetString();
        return text is not null;
    }
}

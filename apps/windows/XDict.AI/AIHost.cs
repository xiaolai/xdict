// The meaning session's model: one question from the captured term and sentence, the reader's entry consent, the
// composed question (which is also the preview), the chosen source, and the mechanical answer validation. Nothing is
// saved here; the pane may offer Save as Note after a validated answer.
using System.Text.Json;
using System.Text.Json.Nodes;

namespace XDict.AI;

public sealed record AIAsk(
    string Term,
    ulong? TermStart,
    ulong? TermLength,
    string Sentence,
    string Language,
    AIMode Mode,
    AIEntryText? Entry = null,
    AISense? Sense = null,
    string? Template = null);

public sealed record AIComposition(
    AIMode Mode,
    string Text,
    string ValidationJson,
    bool Ungrounded,
    bool CarriesEntry);

public sealed record AIAnswer(
    string Outcome,
    string Explanation,
    IReadOnlyList<string> Quotes,
    string? Translation,
    bool Ungrounded,
    string Raw);

public sealed class AIQuestionException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

public sealed class AIAnswerException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

public sealed class AIConsentException() : Exception("consent.entryOff");

public sealed class AIHost(IAISource source)
{
    /// <summary>The composed question, built once and shown as the preview; sending these exact bytes is the contract.</summary>
    public AIComposition Prepare(AIAsk ask, Func<bool> entryConsent)
    {
        (AIMode mode, AIEntryText? entry, AISense? sense) = Effective(ask, entryConsent());
        string template = ask.Template ?? AITemplates.For(ask.Language, mode);
        var input = new JsonObject
        {
            ["template"] = template,
            ["mode"] = mode.Wire(),
            ["term"] = ask.Term,
            ["sentence"] = ask.Sentence,
            ["language"] = ask.Language,
        };
        if (ask.TermStart is { } start && ask.TermLength is { } length)
            input["range"] = new JsonObject { ["start"] = start, ["length"] = length };
        if (entry is not null)
            input["entry"] = new JsonObject
            {
                ["text"] = entry.Text, ["complete"] = entry.Complete, ["cutAt"] = entry.CutAt,
            };
        if (sense is not null)
            input["sense"] = new JsonObject
            {
                ["id"] = sense.Id, ["start"] = sense.Start, ["len"] = sense.Len, ["text"] = sense.Text,
                ["label"] = sense.Label, ["section"] = sense.Section, ["whole"] = sense.Whole,
            };
        using JsonDocument document = JsonDocument.Parse(input.ToJsonString());
        AIComposeResult composed = AIComposer.Compose(document.RootElement);
        if (composed.Status != "ok" || composed.Text is null)
            throw new AIQuestionException(composed.Code ?? "question.invalid");
        return new AIComposition(mode, composed.Text, input.ToJsonString(),
            Ungrounded: mode == AIMode.SentenceOnly, CarriesEntry: entry is not null);
    }

    /// <summary>Sends exactly the prepared bytes; consent is checked again here, at the send boundary.</summary>
    public async Task<AIAnswer> AskAsync(AIComposition composition, Func<bool> entryConsent,
        CancellationToken cancellation = default)
    {
        if (composition.CarriesEntry && !entryConsent()) throw new AIConsentException();
        string raw = await source.AskAsync(composition.Mode, composition.Text, cancellation).ConfigureAwait(false);
        JsonNode? answer;
        try { answer = JsonNode.Parse(raw); }
        catch (JsonException) { throw new AIAnswerException("answer.shape"); }
        if (answer is not JsonObject)
            throw new AIAnswerException("answer.shape");
        JsonObject validation = JsonNode.Parse(composition.ValidationJson)!.AsObject();
        validation["answer"] = answer;
        using JsonDocument document = JsonDocument.Parse(validation.ToJsonString());
        AIValidationResult result = AIValidator.Validate(document.RootElement);
        if (result.Status != "ok")
            throw new AIAnswerException(result.Code ?? "answer.shape");
        return new AIAnswer(result.Outcome!, result.Explanation ?? "", result.Quotes, result.Translation,
            composition.Ungrounded, raw);
    }

    private static (AIMode Mode, AIEntryText? Entry, AISense? Sense) Effective(AIAsk ask, bool consent) =>
        ask.Mode switch
        {
            AIMode.Grounded when !consent => (AIMode.SentenceOnly, null, null),
            AIMode.ExplainSense when !consent => throw new AIConsentException(),
            AIMode.Translate or AIMode.ExplainGrammar or AIMode.SentenceOnly => (ask.Mode, null, null),
            _ => (ask.Mode, ask.Entry, ask.Sense),
        };
}

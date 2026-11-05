// The reader's HTTP source (ADR-0021 d.3), as macOS's sayso provider does it: one OpenAI-compatible chat request at
// the profile's base plus chat/completions, the composed question as the only message, the answer text returned
// unchanged for the validator. DeepSeek's profile sends max_tokens first and negotiates max_completion_tokens on a
// 400/422; redirects are followed only to the same origin; the key travels only where the settings say it belongs and
// is redacted from every error. Every transport failure is typed for the pane's sentence.
using System.Net;
using System.Text;
using System.Text.Json;

namespace XDict.AI;

public enum AIProviderError
{
    NotConfigured,
    NotSignedIn,
    Unreachable,
    Redirect,
    Authentication,
    ModelMissing,
    Busy,
    Malformed,
    Refused,
    Truncated,
    CliFailed,
    Timeout,
    Server,
}

public sealed class AIProviderException(AIProviderError error, string? detail = null)
    : Exception(detail is null ? error.ToString() : error + ": " + detail)
{
    public AIProviderError Error { get; } = error;
    public string? Detail { get; } = detail;
}

public enum AITokenField
{
    MaxTokens,
    MaxCompletionTokens,
}

/// <summary>One service's row in the profile table (sayso's, which macOS uses): base address, key rule, token field.</summary>
public sealed record AIProviderProfile(
    string Id,
    string Name,
    Uri BaseAddress,
    bool KeyRequired,
    AITokenField TokenField,
    IReadOnlyList<string> Models);

public static class AIProviderProfiles
{
    public const string CustomId = "custom";

    public static readonly AIProviderProfile DeepSeek = new(
        "deepseek", "DeepSeek", new Uri("https://api.deepseek.com"), KeyRequired: true,
        AITokenField.MaxTokens, ["deepseek-flash", "deepseek-v4-pro"]);

    /// <summary>The macOS custom row: the reader's address, the key when saved, max_completion_tokens first.</summary>
    public static readonly AIProviderProfile Custom = new(
        CustomId, "Custom (OpenAI-compatible)", new Uri("http://127.0.0.1"), KeyRequired: false,
        AITokenField.MaxCompletionTokens, []);

    public static readonly IReadOnlyList<AIProviderProfile> Known = [DeepSeek];

    /// <summary>The macOS DeepSeek configuration: its base, its default model, the key, max_tokens first, 8,192 tokens.</summary>
    public static AIHttpConfig DeepSeekConfig(string apiKey, string? model = null) => new(
        DeepSeek.BaseAddress, model is null or "" ? "deepseek-flash" : model, apiKey,
        SendKey: true, TokenField: AITokenField.MaxTokens, TokenBudget: 8_192);
}

/// <summary>One ask's HTTP settings. The endpoint is a base; `chat/completions` is appended unless it is already there.</summary>
public sealed record AIHttpConfig(
    Uri Endpoint,
    string Model,
    string? ApiKey = null,
    bool SendKey = false,
    AITokenField TokenField = AITokenField.MaxTokens,
    int TokenBudget = 8_192);

public sealed class AIHttpSource(HttpClient? client = null)
{
    private const int ResponseCap = 1 << 20;
    private const int ErrorCap = 64 << 10;
    private readonly HttpClient owned = client ?? new HttpClient(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        ConnectTimeout = TimeSpan.FromSeconds(10),
    })
    {
        Timeout = TimeSpan.FromSeconds(90),
    };

    public async Task<string> AskAsync(AIHttpConfig config, string composed, CancellationToken cancellation = default)
    {
        if (string.IsNullOrWhiteSpace(config.Model)) throw new AIProviderException(AIProviderError.NotConfigured);
        Uri endpoint = Endpoint(config.Endpoint);
        (HttpResponseMessage response, string firstBody) = await SendAsync(config, composed, endpoint,
            config.TokenField, cancellation).ConfigureAwait(false);
        try
        {
            if (response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.UnprocessableEntity &&
                config.TokenBudget > 0)
            {
                // sayso's negotiation: 400/422 may mean this endpoint wants the other token field. One retry; if it
                // fails, the original reply stands, so its message is what the reader sees.
                string negotiated = firstBody;
                AITokenField other = config.TokenField == AITokenField.MaxTokens
                    ? AITokenField.MaxCompletionTokens
                    : AITokenField.MaxTokens;
                (HttpResponseMessage retry, string retryBody) = await SendAsync(config, composed, endpoint, other,
                    cancellation).ConfigureAwait(false);
                using (retry)
                {
                    if (retry.IsSuccessStatusCode) return await AnswerAsync(retry, retryBody, config, cancellation)
                        .ConfigureAwait(false);
                    throw Server(response.StatusCode, negotiated, config.ApiKey);
                }
            }
            if (!response.IsSuccessStatusCode) throw Failure(response.StatusCode, firstBody, config.ApiKey);
            return await AnswerAsync(response, firstBody, config, cancellation).ConfigureAwait(false);
        }
        finally
        {
            response.Dispose();
        }
    }

    private async Task<(HttpResponseMessage Response, string Body)> SendAsync(AIHttpConfig config, string composed,
        Uri endpoint, AITokenField tokenField, CancellationToken cancellation)
    {
        for (int redirect = 0; ; redirect++)
        {
            var body = new Dictionary<string, object>
            {
                ["model"] = config.Model,
                ["messages"] = new[] { new { role = "user", content = composed } },
                ["temperature"] = 0,
                ["stream"] = false,
            };
            if (config.TokenBudget > 0)
                body[tokenField == AITokenField.MaxTokens ? "max_tokens" : "max_completion_tokens"] = config.TokenBudget;
            using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
            {
                Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json"),
            };
            request.Headers.TryAddWithoutValidation("Accept", "application/json");
            if (config.SendKey && !string.IsNullOrWhiteSpace(config.ApiKey))
                request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + config.ApiKey);
            HttpResponseMessage response;
            try
            {
                response = await owned.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
            {
                throw new AIProviderException(AIProviderError.Timeout);
            }
            catch (HttpRequestException error)
            {
                throw new AIProviderException(AIProviderError.Unreachable, error.Message);
            }
            int status = (int)response.StatusCode;
            if (status is >= 300 and < 400)
            {
                Uri? location = response.Headers.Location is { } relative
                    ? new Uri(endpoint, relative)
                    : null;
                response.Dispose();
                if (location is null || redirect >= 3 || !SameOrigin(endpoint, location))
                    throw new AIProviderException(AIProviderError.Redirect);
                endpoint = location;
                continue;
            }
            string text = await ReadAsync(response, response.IsSuccessStatusCode ? ResponseCap : ErrorCap,
                cancellation).ConfigureAwait(false);
            return (response, text);
        }
    }

    private static async Task<string> AnswerAsync(HttpResponseMessage response, string body, AIHttpConfig config,
        CancellationToken cancellation)
    {
        if (!response.IsSuccessStatusCode) throw Failure(response.StatusCode, body, config.ApiKey);
        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            JsonElement root = document.RootElement;
            if (!root.TryGetProperty("choices", out JsonElement choices) ||
                choices.ValueKind != JsonValueKind.Array || choices.GetArrayLength() == 0)
                throw new AIProviderException(AIProviderError.Malformed);
            JsonElement choice = choices.EnumerateArray().First();
            JsonElement message = choice.GetProperty("message");
            if (message.TryGetProperty("refusal", out JsonElement refusal) &&
                refusal.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(refusal.GetString()))
                throw new AIProviderException(AIProviderError.Refused, refusal.GetString());
            string finish = choice.TryGetProperty("finish_reason", out JsonElement reason) &&
                            reason.ValueKind == JsonValueKind.String ? reason.GetString() ?? "" : "";
            if (finish == "length") throw new AIProviderException(AIProviderError.Truncated);
            if (finish == "content_filter") throw new AIProviderException(AIProviderError.Refused);
            if (finish != "stop")
                throw new AIProviderException(AIProviderError.Malformed, "the answer did not finish: " + finish);
            JsonElement content = message.GetProperty("content");
            if (content.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(content.GetString()))
                throw new AIProviderException(AIProviderError.Malformed);
            return content.GetString()!;
        }
        catch (AIProviderException) { throw; }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException)
        {
            throw new AIProviderException(AIProviderError.Malformed, error.Message);
        }
    }

    private static AIProviderException Failure(HttpStatusCode status, string body, string? key) => (int)status switch
    {
        401 or 403 => new AIProviderException(AIProviderError.Authentication),
        404 => new AIProviderException(AIProviderError.ModelMissing),
        429 or 503 => new AIProviderException(AIProviderError.Busy),
        _ => Server(status, body, key),
    };

    private static AIProviderException Server(HttpStatusCode status, string body, string? key)
    {
        string message = "";
        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            JsonElement root = document.RootElement;
            if (root.TryGetProperty("error", out JsonElement error))
                message = error.ValueKind == JsonValueKind.String
                    ? error.GetString() ?? ""
                    : error.TryGetProperty("message", out JsonElement text) && text.ValueKind == JsonValueKind.String
                        ? text.GetString() ?? ""
                        : "";
        }
        catch (JsonException) { }
        message = string.Join(' ', message.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (message.Length > 300) message = message[..300];
        if (!string.IsNullOrEmpty(key)) message = message.Replace(key, "[key]", StringComparison.Ordinal);
        return new AIProviderException(AIProviderError.Server, $"{(int)status} {message}".Trim());
    }

    private static async Task<string> ReadAsync(HttpResponseMessage response, int cap, CancellationToken cancellation)
    {
        await using Stream stream = await response.Content.ReadAsStreamAsync(cancellation).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var chunk = new byte[16 * 1024];
        while (true)
        {
            int read = await stream.ReadAsync(chunk, cancellation).ConfigureAwait(false);
            if (read == 0) break;
            if (buffer.Length + read > cap) throw new AIProviderException(AIProviderError.Malformed, "response too large");
            buffer.Write(chunk, 0, read);
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    private static Uri Endpoint(Uri baseAddress)
    {
        string text = baseAddress.ToString().TrimEnd('/');
        return text.EndsWith("/chat/completions", StringComparison.OrdinalIgnoreCase)
            ? baseAddress
            : new Uri(text + "/chat/completions");
    }

    private static bool SameOrigin(Uri left, Uri right) =>
        string.Equals(left.Scheme, right.Scheme, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(left.Host, right.Host, StringComparison.OrdinalIgnoreCase) &&
        left.Port == right.Port;
}

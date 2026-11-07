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
    /// <summary>One client for the process unless a test injects its own: a client per source (one per window)
    /// would strand a connection pool each time.</summary>
    private static readonly HttpClient Shared = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        ConnectTimeout = TimeSpan.FromSeconds(10),
    })
    {
        Timeout = TimeSpan.FromSeconds(90),
    };

    /// <summary>The whole ask, headers and body: HttpClient's timeout stops at the headers once the body is read
    /// separately, so a stalled body needs a deadline of its own.</summary>
    private static readonly TimeSpan OverallDeadline = TimeSpan.FromSeconds(120);

    private readonly HttpClient owned = client ?? Shared;

    public async Task<string> AskAsync(AIHttpConfig config, string composed, CancellationToken cancellation = default)
    {
        if (string.IsNullOrWhiteSpace(config.Model)) throw new AIProviderException(AIProviderError.NotConfigured);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(OverallDeadline);
        CancellationToken token = deadline.Token;
        Uri endpoint = Endpoint(config.Endpoint);
        HttpResponseMessage response;
        string firstBody;
        try
        {
            (response, firstBody) = await SendAsync(config, composed, endpoint, config.TokenField, token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw new AIProviderException(AIProviderError.Timeout);
        }
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
                (HttpResponseMessage retry, string retryBody) = await SendAsync(config, composed, endpoint, other, token)
                    .ConfigureAwait(false);
                using (retry)
                {
                    if (retry.IsSuccessStatusCode) return await AnswerAsync(retry, retryBody, config, token)
                        .ConfigureAwait(false);
                    throw Server(response.StatusCode, negotiated, config.ApiKey);
                }
            }
            if (!response.IsSuccessStatusCode) throw Failure(response.StatusCode, firstBody, config.ApiKey);
            return await AnswerAsync(response, firstBody, config, token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw new AIProviderException(AIProviderError.Timeout);
        }
        finally
        {
            response.Dispose();
        }
    }

    private async Task<(HttpResponseMessage Response, string Body)> SendAsync(AIHttpConfig config, string composed,
        Uri endpoint, AITokenField tokenField, CancellationToken cancellation)
    {
        // The key and the reader's sentence must not travel in clear text. HTTPS is required, with the one deliberate
        // exception the custom profile exists for: a model server on this machine, reached over loopback.
        RequireSecureTransport(endpoint);
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
            string text;
            try
            {
                text = await ReadAsync(response, response.IsSuccessStatusCode ? ResponseCap : ErrorCap, cancellation)
                    .ConfigureAwait(false);
            }
            catch
            {
                // A failed body read never returns the response to AskAsync's disposal block.
                response.Dispose();
                throw;
            }
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
                throw new AIProviderException(AIProviderError.Refused, Redact(refusal.GetString(), config.ApiKey));
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
            if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("error", out JsonElement error))
                message = error.ValueKind == JsonValueKind.String
                    ? error.GetString() ?? ""
                    : error.ValueKind == JsonValueKind.Object &&
                      error.TryGetProperty("message", out JsonElement text) && text.ValueKind == JsonValueKind.String
                        ? text.GetString() ?? ""
                        : "";
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException) { }
        // Redaction first: truncating before it can cut a credential in half and leave its prefix in the message.
        message = Redact(message, key);
        message = string.Join(' ', message.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (message.Length > 300) message = message[..300];
        return new AIProviderException(AIProviderError.Server, $"{(int)status} {message}".Trim());
    }

    private static string Redact(string? text, string? key)
    {
        if (string.IsNullOrEmpty(text)) return "";
        return string.IsNullOrEmpty(key) ? text : text.Replace(key, "[key]", StringComparison.Ordinal);
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
        if (baseAddress.AbsolutePath.TrimEnd('/').EndsWith("/chat/completions", StringComparison.OrdinalIgnoreCase))
            return baseAddress;
        var builder = new UriBuilder(baseAddress);
        builder.Path = builder.Path.TrimEnd('/') + "/chat/completions";
        return builder.Uri;
    }

    /// <summary>HTTPS everywhere except a loopback server, which is what the custom profile is for.</summary>
    public static bool SecureEndpoint(Uri endpoint)
    {
        if (endpoint.Scheme == Uri.UriSchemeHttps) return true;
        return endpoint.Scheme == Uri.UriSchemeHttp &&
            (endpoint.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
             (IPAddress.TryParse(endpoint.Host, out IPAddress? address) && IPAddress.IsLoopback(address)));
    }

    private static void RequireSecureTransport(Uri endpoint)
    {
        if (!SecureEndpoint(endpoint))
            throw new AIProviderException(AIProviderError.NotConfigured,
                "the endpoint must be https (plain http is allowed only on this machine)");
    }

    private static bool SameOrigin(Uri left, Uri right) =>
        string.Equals(left.Scheme, right.Scheme, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(left.Host, right.Host, StringComparison.OrdinalIgnoreCase) &&
        left.Port == right.Port;
}

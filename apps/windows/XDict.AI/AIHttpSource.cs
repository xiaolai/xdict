// The reader's HTTP source (ADR-0021 d.3): one OpenAI-compatible chat request, the composed question as the only
// message, the answer text returned unchanged for the validator. Redirects are refused, the key is sent only when the
// settings say this endpoint owns it, and every transport failure is typed for the pane's sentence.
using System.Net;
using System.Text;
using System.Text.Json;

namespace XDict.AI;

public enum AIProviderError
{
    NotConfigured,
    Unreachable,
    Redirect,
    Authentication,
    Busy,
    Malformed,
    Timeout,
}

public sealed class AIProviderException(AIProviderError error, string? detail = null) : Exception(error.ToString())
{
    public AIProviderError Error { get; } = error;
    public string? Detail { get; } = detail;
}

public sealed record AIHttpConfig(Uri Endpoint, string Model, string? ApiKey = null, bool SendKey = false);

public sealed class AIHttpSource(HttpClient? client = null)
{
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
        string payload = JsonSerializer.Serialize(new
        {
            model = config.Model,
            messages = new[] { new { role = "user", content = composed } },
            temperature = 0,
        });
        var request = new HttpRequestMessage(HttpMethod.Post, config.Endpoint)
        {
            Content = new StringContent(payload, Encoding.UTF8, "application/json"),
        };
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
        using (response)
        {
            int status = (int)response.StatusCode;
            if (status is >= 300 and < 400) throw new AIProviderException(AIProviderError.Redirect);
            if (status is 401 or 403) throw new AIProviderException(AIProviderError.Authentication);
            if (status is 429 or 503) throw new AIProviderException(AIProviderError.Busy);
            if (!response.IsSuccessStatusCode)
                throw new AIProviderException(AIProviderError.Unreachable, status.ToString());
            string body;
            try
            {
                body = await response.Content.ReadAsStringAsync(cancellation).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
            {
                throw new AIProviderException(AIProviderError.Timeout);
            }
            return Content(body);
        }
    }

    /// <summary>The provider's message text, or a typed malformed; the app validates the text, never the envelope.</summary>
    private static string Content(string body)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            JsonElement choices = document.RootElement.GetProperty("choices");
            if (choices.ValueKind != JsonValueKind.Array || choices.GetArrayLength() == 0)
                throw new AIProviderException(AIProviderError.Malformed);
            JsonElement first = choices.EnumerateArray().First();
            JsonElement content = first.GetProperty("message").GetProperty("content");
            return content.ValueKind == JsonValueKind.String
                ? content.GetString() ?? throw new AIProviderException(AIProviderError.Malformed)
                : throw new AIProviderException(AIProviderError.Malformed);
        }
        catch (AIProviderException) { throw; }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException)
        {
            throw new AIProviderException(AIProviderError.Malformed, error.Message);
        }
    }
}

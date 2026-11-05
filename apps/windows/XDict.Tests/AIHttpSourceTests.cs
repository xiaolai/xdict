// The HTTP source's transport contract: one composed message, the key only where it belongs, a redirect refused, an
// auth failure and a malformed body typed, and an offline endpoint named. A loopback listener is the only server.
using System.Net;
using System.Net.Sockets;
using System.Text;
using XDict.AI;
using Xunit;

public class AIHttpSourceTests
{
    private sealed class Loopback : IAsyncDisposable
    {
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        private readonly TaskCompletionSource<string> request =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly Task serving;

        public Loopback(int status, string body)
        {
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            Endpoint = new Uri($"http://127.0.0.1:{port}/v1/chat/completions");
            serving = Task.Run(() => ServeAsync(status, body));
        }

        public Uri Endpoint { get; }
        public Task<string> Request => request.Task;

        private async Task ServeAsync(int status, string body)
        {
            try
            {
                using TcpClient client = await listener.AcceptTcpClientAsync();
                NetworkStream stream = client.GetStream();
                string headers = await ReadHeaders(stream);
                int length = 0;
                foreach (string line in headers.Split("\r\n"))
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase) &&
                        int.TryParse(line["Content-Length:".Length..].Trim(), out int parsed)) length = parsed;
                var payload = new byte[length];
                int filled = 0;
                while (filled < length)
                {
                    int read = await stream.ReadAsync(payload.AsMemory(filled));
                    if (read == 0) break;
                    filled += read;
                }
                request.TrySetResult(headers + Encoding.UTF8.GetString(payload, 0, filled));
                byte[] answer = Encoding.UTF8.GetBytes(body);
                string reason = status switch { 200 => "OK", 302 => "Found", 401 => "Unauthorized", _ => "Error" };
                string head = $"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\n" +
                              $"Content-Length: {answer.Length}\r\nConnection: close\r\n\r\n";
                await stream.WriteAsync(Encoding.ASCII.GetBytes(head));
                await stream.WriteAsync(answer);
                await stream.FlushAsync();
            }
            catch (Exception error)
            {
                request.TrySetException(error);
                throw;
            }
        }

        private static async Task<string> ReadHeaders(NetworkStream stream)
        {
            var bytes = new List<byte>();
            var one = new byte[1];
            while (true)
            {
                int read = await stream.ReadAsync(one);
                if (read == 0) break;
                bytes.Add(one[0]);
                if (bytes.Count >= 4 && bytes[^4] == '\r' && bytes[^3] == '\n' && bytes[^2] == '\r' && bytes[^1] == '\n')
                    break;
            }
            return Encoding.ASCII.GetString(bytes.ToArray());
        }

        public async ValueTask DisposeAsync()
        {
            listener.Stop();
            try { await serving; } catch (Exception) { }
        }
    }

    private const string Answer = "{\"outcome\":\"explanationOnly\",\"quotes\":[],\"explanation\":\"It means to hold.\"}";

    private static string Response(string content, string finish = "stop", string? refusal = null) =>
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":" +
        System.Text.Json.JsonSerializer.Serialize(content) +
        (refusal is null ? "" : ",\"refusal\":" + System.Text.Json.JsonSerializer.Serialize(refusal)) +
        "},\"finish_reason\":" + System.Text.Json.JsonSerializer.Serialize(finish) + "}]}";

    private sealed class Sequence : IAsyncDisposable
    {
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        private readonly (int Status, string Body, string? Location)[] replies;
        private readonly List<string> requests = [];
        private readonly Task serving;

        public Sequence(params (int Status, string Body, string? Location)[] replies)
        {
            this.replies = replies;
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            Endpoint = new Uri($"http://127.0.0.1:{port}/v1/chat/completions");
            serving = Task.Run(ServeAsync);
        }

        public Uri Endpoint { get; }

        private async Task ServeAsync()
        {
            try
            {
                foreach ((int status, string body, string? location) in replies)
                {
                    using TcpClient client = await listener.AcceptTcpClientAsync();
                    NetworkStream stream = client.GetStream();
                    string headers = await ReadHeaders(stream);
                    int length = 0;
                    foreach (string line in headers.Split("\r\n"))
                        if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase) &&
                            int.TryParse(line["Content-Length:".Length..].Trim(), out int parsed)) length = parsed;
                    var payload = new byte[length];
                    int filled = 0;
                    while (filled < length)
                    {
                        int read = await stream.ReadAsync(payload.AsMemory(filled));
                        if (read == 0) break;
                        filled += read;
                    }
                    lock (requests) requests.Add(headers + Encoding.UTF8.GetString(payload, 0, filled));
                    byte[] answer = Encoding.UTF8.GetBytes(body);
                    string reason = status switch { 200 => "OK", 302 => "Found", 400 => "Bad Request", _ => "Error" };
                    string head = $"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\n" +
                                  $"Content-Length: {answer.Length}\r\nConnection: close\r\n" +
                                  (location is null ? "" : $"Location: {location}\r\n") + "\r\n";
                    await stream.WriteAsync(Encoding.ASCII.GetBytes(head));
                    await stream.WriteAsync(answer);
                    await stream.FlushAsync();
                }
            }
            catch (Exception) { }
        }

        private static async Task<string> ReadHeaders(NetworkStream stream)
        {
            var bytes = new List<byte>();
            var one = new byte[1];
            while (true)
            {
                int read = await stream.ReadAsync(one);
                if (read == 0) break;
                bytes.Add(one[0]);
                if (bytes.Count >= 4 && bytes[^4] == '\r' && bytes[^3] == '\n' && bytes[^2] == '\r' && bytes[^1] == '\n')
                    break;
            }
            return Encoding.ASCII.GetString(bytes.ToArray());
        }

        public IReadOnlyList<string> Requests { get { lock (requests) return requests.ToArray(); } }

        public async ValueTask DisposeAsync()
        {
            listener.Stop();
            try { await serving; } catch (Exception) { }
        }
    }

    [Fact]
    public async Task TheComposedQuestionIsTheOnlyMessageAndTheKeyTravelsWhenItBelongs()
    {
        await using var server = new Loopback(200, Response(Answer));
        var source = new AIHttpSource();
        string content = await source.AskAsync(
            new AIHttpConfig(server.Endpoint, "model-a", "secret-key", SendKey: true), "THE COMPOSED QUESTION");
        Assert.Equal(Answer, content);
        string request = await server.Request;
        Assert.Contains("Authorization: Bearer secret-key", request);
        Assert.Contains("THE COMPOSED QUESTION", request);
        Assert.Contains("\"model\":\"model-a\"", request);
    }

    [Fact]
    public async Task ALocalEndpointDoesNotGetTheCloudKey()
    {
        await using var server = new Loopback(200, Response(Answer));
        var source = new AIHttpSource();
        await source.AskAsync(new AIHttpConfig(server.Endpoint, "m", "secret-key", SendKey: false), "q");
        Assert.DoesNotContain("Authorization:", await server.Request);
    }

    [Fact]
    public async Task ARedirectIsRefused()
    {
        await using var server = new Loopback(302, "");
        var source = new AIHttpSource();
        var error = await Assert.ThrowsAsync<AIProviderException>(() =>
            source.AskAsync(new AIHttpConfig(server.Endpoint, "m"), "q"));
        Assert.Equal(AIProviderError.Redirect, error.Error);
    }

    [Fact]
    public async Task AnAuthenticationFailureIsTyped()
    {
        await using var server = new Loopback(401, "");
        var source = new AIHttpSource();
        var error = await Assert.ThrowsAsync<AIProviderException>(() =>
            source.AskAsync(new AIHttpConfig(server.Endpoint, "m"), "q"));
        Assert.Equal(AIProviderError.Authentication, error.Error);
    }

    [Fact]
    public async Task AMalformedBodyIsTyped()
    {
        await using var server = new Loopback(200, "{}");
        var source = new AIHttpSource();
        var error = await Assert.ThrowsAsync<AIProviderException>(() =>
            source.AskAsync(new AIHttpConfig(server.Endpoint, "m"), "q"));
        Assert.Equal(AIProviderError.Malformed, error.Error);
    }

    [Fact]
    public async Task AnOfflineEndpointIsTyped()
    {
        int port;
        using (var probe = new TcpListener(IPAddress.Loopback, 0))
        {
            probe.Start();
            port = ((IPEndPoint)probe.LocalEndpoint).Port;
        }
        var source = new AIHttpSource();
        var error = await Assert.ThrowsAsync<AIProviderException>(() =>
            source.AskAsync(new AIHttpConfig(new Uri($"http://127.0.0.1:{port}/v1/chat/completions"), "m"), "q"));
        Assert.Equal(AIProviderError.Unreachable, error.Error);
    }

    [Fact]
    public async Task AnEmptyModelIsNotConfigured()
    {
        var source = new AIHttpSource();
        var error = await Assert.ThrowsAsync<AIProviderException>(() =>
            source.AskAsync(new AIHttpConfig(new Uri("http://127.0.0.1:1/v1/chat/completions"), ""), "q"));
        Assert.Equal(AIProviderError.NotConfigured, error.Error);
    }

    [Fact]
    public void TheDeepSeekProfileIsTheMacOsOne()
    {
        AIHttpConfig config = AIProviderProfiles.DeepSeekConfig("secret");
        Assert.Equal(new Uri("https://api.deepseek.com"), config.Endpoint);
        Assert.Equal("deepseek-flash", config.Model);
        Assert.Equal(AITokenField.MaxTokens, config.TokenField);
        Assert.Equal(8_192, config.TokenBudget);
        Assert.True(config.SendKey);
        Assert.Contains("deepseek-flash", AIProviderProfiles.DeepSeek.Models);
        Assert.Contains("deepseek-v4-pro", AIProviderProfiles.DeepSeek.Models);
    }

    [Fact]
    public async Task DeepSeekAppendsThePathAndNegotiatesTheTokenField()
    {
        await using var server = new Sequence(
            (400, "{\"error\":{\"message\":\"Invalid Parameters\"}}", null),
            (200, Response(Answer), null));
        var source = new AIHttpSource();
        AIHttpConfig config = AIProviderProfiles.DeepSeekConfig("secret") with
        {
            Endpoint = new Uri(server.Endpoint.GetLeftPart(UriPartial.Authority)),
        };
        string content = await source.AskAsync(config, "THE QUESTION");
        Assert.Equal(Answer, content);
        IReadOnlyList<string> requests = server.Requests;
        Assert.Equal(2, requests.Count);
        Assert.Contains("POST /chat/completions", requests[0]);
        Assert.Contains("Authorization: Bearer secret", requests[0]);
        Assert.Contains("\"max_tokens\":8192", requests[0]);
        Assert.Contains("THE QUESTION", requests[0]);
        Assert.Contains("\"max_completion_tokens\":8192", requests[1]);
    }

    [Fact]
    public async Task ALengthFinishIsTruncatedAndAContentFilterIsRefused()
    {
        await using (var server = new Sequence((200, Response(Answer, "length"), null)))
        {
            var error = await Assert.ThrowsAsync<AIProviderException>(() =>
                new AIHttpSource().AskAsync(new AIHttpConfig(server.Endpoint, "m"), "q"));
            Assert.Equal(AIProviderError.Truncated, error.Error);
        }
        await using (var server = new Sequence((200, Response(Answer, "content_filter"), null)))
        {
            var error = await Assert.ThrowsAsync<AIProviderException>(() =>
                new AIHttpSource().AskAsync(new AIHttpConfig(server.Endpoint, "m"), "q"));
            Assert.Equal(AIProviderError.Refused, error.Error);
        }
        await using (var server = new Sequence((200, Response(Answer, refusal: "I will not."), null)))
        {
            var error = await Assert.ThrowsAsync<AIProviderException>(() =>
                new AIHttpSource().AskAsync(new AIHttpConfig(server.Endpoint, "m"), "q"));
            Assert.Equal(AIProviderError.Refused, error.Error);
        }
    }

    [Fact]
    public async Task ASameOriginRedirectIsFollowedAndAnotherOriginIsRefused()
    {
        await using (var server = new Sequence((302, "", "/next"), (200, Response(Answer), null)))
        {
            string content = await new AIHttpSource().AskAsync(new AIHttpConfig(server.Endpoint, "m"), "q");
            Assert.Equal(Answer, content);
            Assert.Equal(2, server.Requests.Count);
            Assert.Contains("POST /next", server.Requests[1]);
        }
        await using (var server = new Sequence((302, "", "https://example.invalid/"), (200, Response(Answer), null)))
        {
            var error = await Assert.ThrowsAsync<AIProviderException>(() =>
                new AIHttpSource().AskAsync(new AIHttpConfig(server.Endpoint, "m"), "q"));
            Assert.Equal(AIProviderError.Redirect, error.Error);
            Assert.Single(server.Requests);
        }
    }

    [Fact]
    public async Task AServerErrorNeverEchoesTheKey()
    {
        await using var server = new Sequence((500, "{\"error\":{\"message\":\"bad secret-key here\"}}", null));
        var error = await Assert.ThrowsAsync<AIProviderException>(() =>
            new AIHttpSource().AskAsync(new AIHttpConfig(server.Endpoint, "m", "secret-key", SendKey: true), "q"));
        Assert.Equal(AIProviderError.Server, error.Error);
        Assert.DoesNotContain("secret-key", error.Detail);
        Assert.Contains("[key]", error.Detail);
    }
}

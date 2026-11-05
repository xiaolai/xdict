// The two CLI sources, as their own official CLIs document them: Codex's non-interactive `exec` with the final message
// in a file, and Claude Code's `-p` with a JSON schema and a JSON envelope. Both take the composed question on stdin,
// run in XDict's own home and working folder, inherit no reader authentication override, and are confined by a job
// object. Their own sign-in decides whether they are offered.
using System.Runtime.Versioning;
using System.Text.Json;

namespace XDict.AI;

public sealed record AICliConfig(string Executable, string Home, string Work, string? Model = null);

public sealed record AICliStatus(bool Ready, string? Version, string? Detail = null);

[SupportedOSPlatform("windows")]
public sealed class CodexCliSource(AICliConfig config)
{
    public static IReadOnlyList<string> Arguments(AICliConfig config, string lastMessage)
    {
        var arguments = new List<string>
        {
            "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
            "--disable", "shell_tool", "--disable", "browser_use", "--disable", "unified_exec",
            "-s", "read-only", "-C", config.Work,
            "-c", "approval_policy=\"never\"", "-c", "mcp_servers={}",
            "-o", lastMessage,
        };
        if (!string.IsNullOrWhiteSpace(config.Model)) { arguments.Add("-m"); arguments.Add(config.Model); }
        arguments.Add("-");
        return arguments;
    }

    public async Task<string> AskAsync(string composed, CancellationToken cancellation = default)
    {
        Prepare();
        string last = Path.Combine(config.Work, "last-message-" + Guid.NewGuid().ToString("N") + ".txt");
        try
        {
            using var process = new AIProcess(config.Executable, Arguments(config, last), config.Work,
                AICliEnvironment.For("CODEX_HOME", config.Home));
            await process.RunAsync(composed, TimeSpan.FromSeconds(180), cancellation).ConfigureAwait(false);
            if (!File.Exists(last)) throw new AIProviderException(AIProviderError.Malformed, "no final message");
            string answer = await File.ReadAllTextAsync(last, cancellation).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(answer))
                throw new AIProviderException(AIProviderError.Malformed, "an empty final message");
            return answer;
        }
        finally
        {
            File.Delete(last);
        }
    }

    public async Task<AICliStatus> CheckAsync(CancellationToken cancellation = default)
    {
        Prepare();
        try
        {
            using (var status = new AIProcess(config.Executable, ["login", "status"], config.Work,
                       AICliEnvironment.For("CODEX_HOME", config.Home)))
            {
                string text = await status.RunAsync("", TimeSpan.FromSeconds(30), cancellation).ConfigureAwait(false);
                if (!text.Contains("Logged in", StringComparison.OrdinalIgnoreCase))
                    return new AICliStatus(false, null, "not signed in in XDict's Codex home");
            }
            using var version = new AIProcess(config.Executable, ["--version"], config.Work,
                AICliEnvironment.For("CODEX_HOME", config.Home));
            string found = (await version.RunAsync("", TimeSpan.FromSeconds(30), cancellation)
                .ConfigureAwait(false)).Trim();
            return new AICliStatus(true, found);
        }
        catch (AIProviderException error) when (error.Error == AIProviderError.CliFailed)
        {
            return new AICliStatus(false, null, "not signed in in XDict's Codex home");
        }
    }

    private void Prepare()
    {
        if (string.IsNullOrWhiteSpace(config.Executable) || !File.Exists(config.Executable))
            throw new AIProviderException(AIProviderError.NotConfigured, "codex was not found");
        Directory.CreateDirectory(config.Home);
        Directory.CreateDirectory(config.Work);
    }
}

[SupportedOSPlatform("windows")]
public sealed class ClaudeCliSource(AICliConfig config)
{
    public static IReadOnlyList<string> Arguments(AICliConfig config, AIMode mode)
    {
        var arguments = new List<string>
        {
            "-p", "--output-format", "json", "--json-schema", AIAnswerSchemas.For(mode),
            "--no-session-persistence", "--tools", "", "--strict-mcp-config",
            "--setting-sources", "", "--disable-slash-commands",
            "--permission-prompts", "none", "--safe-mode",
        };
        if (!string.IsNullOrWhiteSpace(config.Model)) { arguments.Add("--model"); arguments.Add(config.Model); }
        return arguments;
    }

    public async Task<string> AskAsync(AIMode mode, string composed, CancellationToken cancellation = default)
    {
        Prepare();
        using var process = new AIProcess(config.Executable, Arguments(config, mode), config.Work,
            AICliEnvironment.For("CLAUDE_CONFIG_DIR", config.Home));
        string stdout = await process.RunAsync(composed, TimeSpan.FromSeconds(120), cancellation).ConfigureAwait(false);
        return Answer(stdout);
    }

    /// <summary>The envelope's structured output, or its result; an error envelope is never a plausible answer.</summary>
    public static string Answer(string stdout)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(stdout);
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new AIProviderException(AIProviderError.Malformed);
            bool error = root.TryGetProperty("is_error", out JsonElement isError) &&
                         isError.ValueKind == JsonValueKind.True;
            if (root.TryGetProperty("subtype", out JsonElement subtype) &&
                subtype.ValueKind == JsonValueKind.String && subtype.GetString() != "success")
                error = true;
            if (error)
            {
                string why = root.TryGetProperty("result", out JsonElement reason) &&
                             reason.ValueKind == JsonValueKind.String
                    ? reason.GetString() ?? ""
                    : "";
                throw new AIProviderException(AIProviderError.Refused, why);
            }
            if (root.TryGetProperty("structured_output", out JsonElement structured) &&
                structured.ValueKind != JsonValueKind.Null)
                return structured.GetRawText();
            if (root.TryGetProperty("result", out JsonElement result) && result.ValueKind == JsonValueKind.String &&
                !string.IsNullOrWhiteSpace(result.GetString()))
                return result.GetString()!;
            throw new AIProviderException(AIProviderError.Malformed);
        }
        catch (AIProviderException) { throw; }
        catch (JsonException error)
        {
            throw new AIProviderException(AIProviderError.Malformed, error.Message);
        }
    }

    public async Task<AICliStatus> CheckAsync(CancellationToken cancellation = default)
    {
        Prepare();
        try
        {
            using (var status = new AIProcess(config.Executable, ["auth", "status"], config.Work,
                       AICliEnvironment.For("CLAUDE_CONFIG_DIR", config.Home)))
            {
                string text = await status.RunAsync("", TimeSpan.FromSeconds(30), cancellation).ConfigureAwait(false);
                // The official command exits 0 only when signed in; the JSON names the method, not a secret.
                if (text.Contains("\"authMethod\":\"none\"", StringComparison.Ordinal))
                    return new AICliStatus(false, null, "not signed in in XDict's Claude configuration");
            }
            using var version = new AIProcess(config.Executable, ["--version"], config.Work,
                AICliEnvironment.For("CLAUDE_CONFIG_DIR", config.Home));
            string found = (await version.RunAsync("", TimeSpan.FromSeconds(30), cancellation)
                .ConfigureAwait(false)).Trim();
            return new AICliStatus(true, found);
        }
        catch (AIProviderException error) when (error.Error == AIProviderError.CliFailed)
        {
            return new AICliStatus(false, null, "not signed in in XDict's Claude configuration");
        }
    }

    private void Prepare()
    {
        if (string.IsNullOrWhiteSpace(config.Executable) || !File.Exists(config.Executable))
            throw new AIProviderException(AIProviderError.NotConfigured, "claude was not found");
        Directory.CreateDirectory(config.Home);
        Directory.CreateDirectory(config.Work);
    }
}

[SupportedOSPlatform("windows")]
public static class AICliEnvironment
{
    private static readonly string[] AuthOverrides =
    [
        "OPENAI_API_KEY", "CODEX_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_MODEL",
    ];

    /// <summary>The child's environment: the app's, minus every reader authentication override, with its own home.</summary>
    public static IReadOnlyDictionary<string, string> For(string homeVariable, string home)
    {
        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
            if (entry.Key is string key && entry.Value is string value) environment[key] = value;
        foreach (string key in AuthOverrides) environment.Remove(key);
        environment[homeVariable] = home;
        return environment;
    }
}

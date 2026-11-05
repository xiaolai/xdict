// The reader's AI choices, as Settings ▸ AI keeps them: the source, DeepSeek's base and model, the entry switch, the
// answer language and the preview. The key is not in this file; it is the one item WindowsCredentialStore holds.
using System.Runtime.Versioning;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace XDict.AI;

public enum AISourceKind
{
    Off,
    Http,
    CodexCli,
    ClaudeCli,
}

public interface IAISource
{
    Task<string> AskAsync(AIMode mode, string composed, CancellationToken cancellation = default);
}

public sealed record AISettings
{
    public AISourceKind Source { get; init; } = AISourceKind.Off;

    /// <summary>The profile id: DeepSeek by default, or custom for the reader's own address.</summary>
    public string HttpProfile { get; init; } = AIProviderProfiles.DeepSeek.Id;

    /// <summary>The base address; `chat/completions` is appended by the source unless it is already there.</summary>
    public string Endpoint { get; init; } = "https://api.deepseek.com";

    public string Model { get; init; } = "deepseek-flash";

    /// <summary>The entry text leaves only under this switch (ADR-0021 d.4); the sentence does not need it.</summary>
    public bool SendEntryText { get; init; }

    /// <summary>The answer's language, a BCP 47 tag.</summary>
    public string Language { get; init; } = "en";

    public bool PreviewBeforeSending { get; init; } = true;
    public bool AskOnOpen { get; init; } = true;

    public string? CodexExecutable { get; init; }
    public string? ClaudeExecutable { get; init; }
    public string? CodexModel { get; init; }
    public string? ClaudeModel { get; init; }

    [JsonIgnore]
    public static string Folder =>
        Environment.GetEnvironmentVariable("XDICT_AI_HOME")
        ?? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDict", "AI");

    [JsonIgnore]
    public static string FilePath =>
        Environment.GetEnvironmentVariable("XDICT_AI_SETTINGS") ?? System.IO.Path.Combine(Folder, "ai.json");

    [JsonIgnore]
    public string CodexHome => System.IO.Path.Combine(Folder, "codex");
    [JsonIgnore]
    public string ClaudeHome => System.IO.Path.Combine(Folder, "claude");
    [JsonIgnore]
    public string Work => System.IO.Path.Combine(Folder, "work");

    public AIProviderProfile Profile =>
        AIProviderProfiles.Known.FirstOrDefault(item => item.Id == HttpProfile)
        ?? (HttpProfile == AIProviderProfiles.CustomId ? AIProviderProfiles.Custom : AIProviderProfiles.DeepSeek);

    /// <summary>DeepSeek by macOS's rule: its base, its default model, Bearer, max_tokens first, 8,192 tokens.</summary>
    public AIHttpConfig HttpConfig(string? key)
    {
        AIProviderProfile profile = Profile;
        Uri endpoint = string.IsNullOrWhiteSpace(Endpoint)
            ? profile.BaseAddress
            : new Uri(Endpoint.TrimEnd('/'));
        string model = string.IsNullOrWhiteSpace(Model)
            ? profile.Models.FirstOrDefault() ?? ""
            : Model;
        return new AIHttpConfig(endpoint, model, key,
            SendKey: !string.IsNullOrEmpty(key) && (profile.KeyRequired || HttpProfile == AIProviderProfiles.CustomId),
            TokenField: profile.TokenField, TokenBudget: 8_192);
    }

    public AICliConfig? CodexConfig()
    {
        string? executable = CodexExecutable ?? FindOnPath("codex.exe");
        return string.IsNullOrWhiteSpace(executable) || !System.IO.File.Exists(executable)
            ? null
            : new AICliConfig(executable, CodexHome, Work, string.IsNullOrWhiteSpace(CodexModel) ? null : CodexModel);
    }

    public AICliConfig? ClaudeConfig()
    {
        string? executable = ClaudeExecutable ?? FindOnPath("claude.exe");
        return string.IsNullOrWhiteSpace(executable) || !System.IO.File.Exists(executable)
            ? null
            : new AICliConfig(executable, ClaudeHome, Work, string.IsNullOrWhiteSpace(ClaudeModel) ? null : ClaudeModel);
    }

    public static AISettings Load(string? path = null)
    {
        path ??= FilePath;
        try
        {
            if (!System.IO.File.Exists(path)) return new AISettings();
            return JsonSerializer.Deserialize<AISettings>(System.IO.File.ReadAllText(path)) ?? new AISettings();
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException)
        {
            return new AISettings();
        }
    }

    public void Save(string? path = null)
    {
        path ??= FilePath;
        System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            System.IO.File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            System.IO.File.Move(temporary, path, true);
        }
        finally
        {
            System.IO.File.Delete(temporary);
        }
    }

    /// <summary>A PATH lookup without a shell; an empty entry is skipped.</summary>
    public static string? FindOnPath(string name)
    {
        foreach (string directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(
                     System.IO.Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                string candidate = System.IO.Path.Combine(directory.Trim('"'), name);
                if (System.IO.File.Exists(candidate)) return candidate;
            }
            catch (Exception error) when (error is ArgumentException or NotSupportedException) { }
        }
        return null;
    }
}

public static class AISourceFactory
{
    [SupportedOSPlatform("windows")]
    public static IAISource Create(AISettings settings, string? key, AIHttpSource? http = null) => settings.Source switch
    {
        AISourceKind.Http => new HttpAdapter(settings.HttpConfig(key), http ?? new AIHttpSource()),
        AISourceKind.CodexCli => new CodexAdapter(new CodexCliSource(
            settings.CodexConfig() ?? throw new AIProviderException(AIProviderError.NotConfigured, "codex was not found"))),
        AISourceKind.ClaudeCli => new ClaudeAdapter(new ClaudeCliSource(
            settings.ClaudeConfig() ?? throw new AIProviderException(AIProviderError.NotConfigured, "claude was not found"))),
        _ => throw new AIProviderException(AIProviderError.NotConfigured),
    };

    private sealed class HttpAdapter(AIHttpConfig config, AIHttpSource source) : IAISource
    {
        public Task<string> AskAsync(AIMode mode, string composed, CancellationToken cancellation = default) =>
            source.AskAsync(config, composed, cancellation);
    }

    [SupportedOSPlatform("windows")]
    private sealed class CodexAdapter(CodexCliSource source) : IAISource
    {
        public Task<string> AskAsync(AIMode mode, string composed, CancellationToken cancellation = default) =>
            source.AskAsync(composed, cancellation);
    }

    [SupportedOSPlatform("windows")]
    private sealed class ClaudeAdapter(ClaudeCliSource source) : IAISource
    {
        public Task<string> AskAsync(AIMode mode, string composed, CancellationToken cancellation = default) =>
            source.AskAsync(mode, composed, cancellation);
    }
}

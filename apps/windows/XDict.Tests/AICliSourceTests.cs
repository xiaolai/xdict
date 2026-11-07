// The CLI sources' arguments and envelope parsing: official documented flags, no shell, the prompt on stdin, the
// private home, and Claude's structured output/result/error order. No model is asked.
using System.Runtime.Versioning;
using XDict.AI;
using Xunit;

[SupportedOSPlatform("windows")]
public class AICliSourceTests
{
    private static readonly AICliConfig Config = new("C:\\tools\\codex.exe", "C:\\home", "C:\\work", "model-x");

    [Fact]
    public void TheCodexArgumentsAreTheDocumentedConfinedExec()
    {
        IReadOnlyList<string> arguments = CodexCliSource.Arguments(Config, "C:\\work\\last.txt");
        Assert.Equal("exec", arguments[0]);
        Assert.Contains("--ephemeral", arguments);
        Assert.Contains("--ignore-user-config", arguments);
        Assert.Contains("--ignore-rules", arguments);
        Assert.Contains("--skip-git-repo-check", arguments);
        Assert.Contains("-s", arguments);
        Assert.Contains("read-only", arguments);
        Assert.Contains("-C", arguments);
        Assert.Contains("C:\\work", arguments);
        Assert.Contains("-c", arguments);
        Assert.Contains("mcp_servers={}", arguments);
        Assert.Contains("--disable", arguments);
        Assert.Contains("shell_tool", arguments);
        Assert.Contains("browser_use", arguments);
        Assert.Contains("unified_exec", arguments);
        Assert.Contains("-o", arguments);
        Assert.Contains("C:\\work\\last.txt", arguments);
        Assert.Contains("-m", arguments);
        Assert.Contains("model-x", arguments);
        Assert.Equal("-", arguments[^1]); // the prompt is stdin, never an argument
    }

    [Fact]
    public void TheClaudeArgumentsAreTheDocumentedStructuredPrint()
    {
        IReadOnlyList<string> arguments = ClaudeCliSource.Arguments(Config, AIMode.Grounded);
        Assert.Equal("-p", arguments[0]);
        Assert.Contains("--output-format", arguments);
        Assert.Contains("json", arguments);
        Assert.Contains("--json-schema", arguments);
        Assert.Contains(AIAnswerSchemas.Meaning, arguments);
        Assert.Contains("--no-session-persistence", arguments);
        Assert.Contains("--tools", arguments);
        Assert.Contains("", arguments);
        Assert.Contains("--strict-mcp-config", arguments);
        Assert.Contains("--setting-sources", arguments);
        Assert.Contains("--disable-slash-commands", arguments);
        Assert.Contains("--permission-prompts", arguments);
        Assert.Contains("none", arguments);
        Assert.Contains("--safe-mode", arguments);
        Assert.Contains("--model", arguments);
        Assert.Contains("model-x", arguments);
    }

    [Fact]
    public void EachModeGetsItsOwnSchema()
    {
        Assert.Contains(AIAnswerSchemas.Translation, ClaudeCliSource.Arguments(Config, AIMode.Translate));
        Assert.Contains(AIAnswerSchemas.Grammar, ClaudeCliSource.Arguments(Config, AIMode.ExplainGrammar));
    }

    [Fact]
    public void ClaudePrefersStructuredOutputThenResult()
    {
        Assert.Equal("{\"outcome\":\"explanationOnly\",\"quotes\":[],\"explanation\":\"x\"}",
            ClaudeCliSource.Answer(
                "{\"is_error\":false,\"subtype\":\"success\",\"result\":\"fallback\"," +
                "\"structured_output\":{\"outcome\":\"explanationOnly\",\"quotes\":[],\"explanation\":\"x\"}}"));
        Assert.Equal("the result",
            ClaudeCliSource.Answer("{\"is_error\":false,\"subtype\":\"success\",\"result\":\"the result\"}"));
    }

    [Fact]
    public void AnErrorEnvelopeIsRefusedAndABadEnvelopeIsMalformed()
    {
        var refused = Assert.Throws<AIProviderException>(() =>
            ClaudeCliSource.Answer("{\"is_error\":true,\"result\":\"I will not answer.\"}"));
        Assert.Equal(AIProviderError.Refused, refused.Error);
        var malformed = Assert.Throws<AIProviderException>(() => ClaudeCliSource.Answer("not json"));
        Assert.Equal(AIProviderError.Malformed, malformed.Error);
    }

    [Fact]
    public void TheChildEnvironmentDropsReaderAuthenticationOverrides()
    {
        Environment.SetEnvironmentVariable("ANTHROPIC_API_KEY", "reader-secret");
        Environment.SetEnvironmentVariable("OPENAI_API_KEY", "reader-secret");
        try
        {
            IReadOnlyDictionary<string, string> environment = AICliEnvironment.For("CODEX_HOME", "C:\\xdict\\codex");
            Assert.False(environment.ContainsKey("ANTHROPIC_API_KEY"));
            Assert.False(environment.ContainsKey("OPENAI_API_KEY"));
            Assert.Equal("C:\\xdict\\codex", environment["CODEX_HOME"]);
        }
        finally
        {
            Environment.SetEnvironmentVariable("ANTHROPIC_API_KEY", null);
            Environment.SetEnvironmentVariable("OPENAI_API_KEY", null);
        }
    }

    /// <summary>The dictionary is not the proof: the child process must not see the reader's credentials even
    /// though the parent's environment holds them (the overlay alone would leave them in place).</summary>
    [Fact]
    public async Task TheOsChildDoesNotInheritTheReadersAuthenticationOverrides()
    {
        Environment.SetEnvironmentVariable("ANTHROPIC_API_KEY", "sentinel-reader-secret");
        try
        {
            using var process = new AIProcess("cmd.exe", ["/d", "/c", "set"], Path.GetTempPath(),
                AICliEnvironment.For("CODEX_HOME", "C:\\xdict\\codex"));
            string output = await process.RunAsync("", TimeSpan.FromSeconds(30));
            Assert.DoesNotContain("ANTHROPIC_API_KEY", output);
            Assert.DoesNotContain("sentinel-reader-secret", output);
            Assert.Contains("CODEX_HOME=C:\\xdict\\codex", output);
        }
        finally
        {
            Environment.SetEnvironmentVariable("ANTHROPIC_API_KEY", null);
        }
    }
}

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
        // The whole sequence, in order: membership alone let a flag and its value drift apart, and one empty
        // argument satisfied a "contains" check for any flag.
        Assert.Equal(new[]
        {
            "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
            "--disable", "shell_tool", "--disable", "browser_use", "--disable", "unified_exec",
            "-s", "read-only", "-C", "C:\\work",
            "-c", "approval_policy=\"never\"", "-c", "mcp_servers={}",
            "-o", "C:\\work\\last.txt",
            "-m", "model-x",
            "-", // the prompt is stdin, never an argument
        }, CodexCliSource.Arguments(Config, "C:\\work\\last.txt"));
    }

    [Fact]
    public void TheClaudeArgumentsAreTheDocumentedStructuredPrint()
    {
        Assert.Equal(new[]
        {
            "-p", "--output-format", "json", "--json-schema", AIAnswerSchemas.Meaning,
            "--no-session-persistence", "--tools", "", "--strict-mcp-config",
            "--setting-sources", "", "--disable-slash-commands",
            "--permission-prompts", "none", "--safe-mode",
            "--model", "model-x",
        }, ClaudeCliSource.Arguments(Config, AIMode.Grounded));
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

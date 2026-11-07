// The CLI child: stdin carries the composed question, a non-zero status and a timeout are typed, and the job object
// kills the child it confined. The child is cmd.exe; no product CLI is needed for these transport checks.
using System.Runtime.Versioning;
using XDict.AI;
using Xunit;

[SupportedOSPlatform("windows")]
public class AIProcessTests
{
    private static string Command => Environment.GetEnvironmentVariable("ComSpec")!;
    private static readonly string Work =
        Path.Combine(Path.GetTempPath(), "xdict-ai-process-" + Guid.NewGuid().ToString("N"));

    private static AIProcess Start(params string[] arguments)
    {
        Directory.CreateDirectory(Work);
        // The child gets exactly this environment: a command interpreter needs the system paths to find a built-in
        // tool, so an empty dictionary is not a valid test child.
        var environment = new Dictionary<string, string>();
        foreach (string name in new[] { "PATH", "SystemRoot", "ComSpec", "TEMP", "TMP" })
            if (Environment.GetEnvironmentVariable(name) is { Length: > 0 } value) environment[name] = value;
        return new AIProcess(Command, arguments, Work, environment);
    }

    [Fact]
    public async Task ThePromptTravelsOnStdinAndTheChildOutputComesBack()
    {
        using var process = Start("/c", "more");
        string output = await process.RunAsync("THE COMPOSED QUESTION", TimeSpan.FromSeconds(10));
        Assert.Contains("THE COMPOSED QUESTION", output);
    }

    [Fact]
    public async Task ANonZeroExitIsTyped()
    {
        using var process = Start("/c", "exit 3");
        var error = await Assert.ThrowsAsync<AIProviderException>(() =>
            process.RunAsync("", TimeSpan.FromSeconds(10)));
        Assert.Equal(AIProviderError.CliFailed, error.Error);
    }

    [Fact]
    public async Task ATimeoutKillsTheConfinedChild()
    {
        using var process = Start("/c", "ping", "-n", "30", "127.0.0.1");
        var error = await Assert.ThrowsAsync<AIProviderException>(() =>
            process.RunAsync("", TimeSpan.FromSeconds(1)));
        Assert.Equal(AIProviderError.Timeout, error.Error);
        Assert.True(process.Process.HasExited);
    }
}

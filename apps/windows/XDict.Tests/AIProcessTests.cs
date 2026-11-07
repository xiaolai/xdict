// The CLI child: stdin carries the composed question, a non-zero status and a timeout are typed, and the job object
// kills the child it confined, its descendants included. The child is cmd.exe; no product CLI is needed for these
// transport checks.
using System.Diagnostics;
using System.Runtime.Versioning;
using XDict.AI;
using Xunit;

[SupportedOSPlatform("windows")]
public class AIProcessTests : IDisposable
{
    // One folder per test instance: xUnit creates one instance per test, and Dispose removes what the child left in it.
    private readonly string work = Path.Combine(Path.GetTempPath(), "xdict-ai-process-" + Guid.NewGuid().ToString("N"));

    private static string Command => Environment.GetEnvironmentVariable("ComSpec")!;

    private AIProcess Start(params string[] arguments)
    {
        Directory.CreateDirectory(work);
        // The child gets exactly this environment: a command interpreter needs the system paths to find a built-in
        // tool, so an empty dictionary is not a valid test child.
        var environment = new Dictionary<string, string>();
        foreach (string name in new[] { "PATH", "SystemRoot", "ComSpec", "TEMP", "TMP" })
            if (Environment.GetEnvironmentVariable(name) is { Length: > 0 } value) environment[name] = value;
        return new AIProcess(Command, arguments, work, environment);
    }

    public void Dispose()
    {
        try { Directory.Delete(work, true); } catch (DirectoryNotFoundException) { }
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
    public async Task ATimeoutKillsTheChildAndItsDescendant()
    {
        // The descendant, not only the parent: a job object that confined the parent alone would leave ping running.
        HashSet<int> before = Running("ping");
        using var process = Start("/c", "ping", "-n", "30", "127.0.0.1");
        int parent = process.Process.Id;
        Task<string> running = process.RunAsync("", TimeSpan.FromSeconds(4));
        await Task.Delay(1500);
        int[] descendants = Running("ping").Except(before).ToArray();
        // Without a descendant this test proves nothing about the job; the assertion is the evidence that it did.
        Assert.NotEmpty(descendants);
        var error = await Assert.ThrowsAsync<AIProviderException>(() => running);
        Assert.Equal(AIProviderError.Timeout, error.Error);
        await GoneAsync(parent);
        foreach (int descendant in descendants) await GoneAsync(descendant);
    }

    [Fact]
    public async Task CancellationKillsTheChild()
    {
        using var process = Start("/c", "ping", "-n", "30", "127.0.0.1");
        int parent = process.Process.Id;
        using var cancellation = new CancellationTokenSource();
        Task<string> running = process.RunAsync("", TimeSpan.FromSeconds(30), cancellation.Token);
        await Task.Delay(500);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => running);
        await GoneAsync(parent);
    }

    [Fact]
    public void DisposalKillsTheChild()
    {
        AIProcess process = Start("/c", "ping", "-n", "30", "127.0.0.1");
        int parent = process.Process.Id;
        process.Dispose();
        Assert.True(WaitGone(parent));
    }

    private static HashSet<int> Running(string name)
    {
        try { return System.Diagnostics.Process.GetProcessesByName(name).Select(item => item.Id).ToHashSet(); }
        catch (InvalidOperationException) { return []; }
    }

    private static async Task GoneAsync(int id)
    {
        Assert.True(await Task.Run(() => WaitGone(id)),
            $"process {id} survived the job object's termination");
    }

    private static bool WaitGone(int id)
    {
        for (int attempt = 0; attempt < 100; attempt++)
        {
            try
            {
                using Process child = Process.GetProcessById(id);
                if (child.HasExited) return true;
            }
            catch (ArgumentException) { return true; }
            Thread.Sleep(100);
        }
        return false;
    }
}

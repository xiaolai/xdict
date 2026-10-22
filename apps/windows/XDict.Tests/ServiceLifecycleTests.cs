using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using XDict.Client;
using XDict.Contract;
using Xunit;
using System.Text.Json;

public class ServiceLifecycleTests
{
    [DllImport("ntdll.dll")]
    private static extern int NtSuspendProcess(SafeProcessHandle process);
    [DllImport("ntdll.dll")]
    private static extern int NtResumeProcess(SafeProcessHandle process);

    private static ServiceClient Start(TimeSpan? deadline = null) => new(
        Environment.GetEnvironmentVariable("XDICT_SERVICE")!, new ServiceClientOptions
        {
            Storage = "test-" + Guid.NewGuid().ToString("N"),
            LookupDeadline = deadline ?? TimeSpan.FromSeconds(5),
        });

    private static string? Error(Reply reply) => reply.Error?.GetProperty("type").GetString();

    [Fact]
    public async Task ConcurrentRepliesAreDemultiplexedById()
    {
        using var client = Start();
        var replies = await Task.WhenAll(Enumerable.Range(0, 40).Select(_ => client.CallAsync("versions", null)));
        Assert.All(replies, reply => Assert.Null(reply.Error));
        Assert.Equal(40, replies.Select(reply => reply.Id).Distinct().Count());
    }

    [Fact]
    public async Task ASupersededLateReplyIsNeverDelivered()
    {
        using var client = Start();
        client.Handshake();
        using var process = Process.GetProcessById(client.ProcessId);
        Assert.Equal(0, NtSuspendProcess(process.SafeHandle));
        try
        {
            var sent = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            client.RequestSent += (_, _) => sent.TrySetResult();
            var old = client.CallAsync("versions", null, generation: client.NewGeneration("query"));
            await sent.Task.WaitAsync(TimeSpan.FromSeconds(2));
            _ = client.NewGeneration("query");
            Assert.Equal(0, NtResumeProcess(process.SafeHandle));
            Assert.Equal("cancelled", Error(await old.WaitAsync(TimeSpan.FromSeconds(2))));
            Assert.NotNull(client.Handshake());
        }
        finally { _ = NtResumeProcess(process.SafeHandle); }
    }

    [Fact]
    public async Task AQueuedSupersededRequestNeverCrossesThePipe()
    {
        using var client = Start();
        client.Handshake();
        using var process = Process.GetProcessById(client.ProcessId);
        Assert.Equal(0, NtSuspendProcess(process.SafeHandle));
        try
        {
            int sent = 0;
            var full = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            client.RequestSent += (_, _) => { if (Interlocked.Increment(ref sent) == 8) full.TrySetResult(); };
            var active = Enumerable.Range(0, 8).Select(_ => client.CallAsync("versions", null)).ToArray();
            await full.Task.WaitAsync(TimeSpan.FromSeconds(2));
            var queued = client.CallAsync("versions", null, generation: client.NewGeneration("query"));
            _ = client.NewGeneration("query");
            Assert.Equal(0, NtResumeProcess(process.SafeHandle));
            Reply superseded = await queued.WaitAsync(TimeSpan.FromSeconds(2));
            await Task.WhenAll(active).WaitAsync(TimeSpan.FromSeconds(2));
            Assert.Equal(8, Volatile.Read(ref sent));
            Assert.Equal("cancelled", Error(superseded));
        }
        finally { _ = NtResumeProcess(process.SafeHandle); }
    }

    [Fact]
    public async Task AStallExpiresAndTheNextConnectionHasAllItsCredits()
    {
        using var client = Start(TimeSpan.FromMilliseconds(400));
        client.Handshake();
        int original = client.ProcessId;
        using var process = Process.GetProcessById(original);
        Assert.Equal(0, NtSuspendProcess(process.SafeHandle));
        var calls = Enumerable.Range(0, 8).Select(_ => client.CallAsync("versions", null)).ToArray();
        var replies = await Task.WhenAll(calls).WaitAsync(TimeSpan.FromSeconds(4));
        Assert.Contains(replies, reply => Error(reply) == "deadline");
        Assert.All(replies, reply => Assert.Contains(Error(reply), new[] { "deadline", "staleHandle" }));
        Assert.NotNull(client.Handshake());
        Assert.NotEqual(original, client.ProcessId);
        var healthy = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => client.CallAsync("versions", null)));
        Assert.All(healthy, reply => Assert.Null(reply.Error));
    }

    [Fact]
    public async Task KillDuringACallReturnsTypedStaleAndTheNextCallSucceeds()
    {
        using var client = Start();
        client.Handshake();
        using var process = Process.GetProcessById(client.ProcessId);
        Assert.Equal(0, NtSuspendProcess(process.SafeHandle));
        var sent = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        client.RequestSent += (_, _) => sent.TrySetResult();
        var call = client.CallAsync("lookup", new { query = "run", dicts = Array.Empty<string>(), options = new { limit = 10, offset = 0, mode = "reader" } });
        await sent.Task.WaitAsync(TimeSpan.FromSeconds(2));
        process.Kill();
        Assert.Equal("staleHandle", Error(await call.WaitAsync(TimeSpan.FromSeconds(2))));
        Assert.NotNull(client.Handshake());
    }

    [Fact]
    public async Task KillMidLookupReopensThePackageAndReadsTheSameEdition()
    {
        using var client = Start();
        string fixture = Path.Combine(Environment.GetEnvironmentVariable("XDICT_FIXTURES")!, "tiny", "tiny.mdx");
        object[] files = [client.Observe("tiny", "tiny", fixture)];
        var package = new { mdx = new { file = "tiny" } };
        Assert.Null(client.Call("import", new { package }, files).Error);
        Reply opened = client.Call("open", new { package }, files);
        Assert.Null(opened.Error);
        string dict = opened.Ok!.Value.GetProperty("dict").GetString()!;
        var body = new { query = "run", dicts = new[] { dict }, options = new { limit = 10, offset = 0, mode = "reader" } };
        Reply first = client.Call("lookup", body);
        Assert.Null(first.Error);
        Assert.True(first.Ok!.Value.GetProperty("hits").GetArrayLength() > 0);
        using var process = Process.GetProcessById(client.ProcessId);
        Assert.Equal(0, NtSuspendProcess(process.SafeHandle));
        var sent = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        client.RequestSent += (_, _) => sent.TrySetResult();
        var call = client.CallAsync("lookup", body);
        await sent.Task.WaitAsync(TimeSpan.FromSeconds(2));
        process.Kill();
        Assert.Equal("staleHandle", Error(await call.WaitAsync(TimeSpan.FromSeconds(2))));
        Reply second = client.Call("lookup", body);
        Assert.Null(second.Error);
        Assert.Equal(first.Ok.Value.GetProperty("hits").EnumerateArray().Select(hit => hit.GetProperty("entry").GetRawText()),
            second.Ok!.Value.GetProperty("hits").EnumerateArray().Select(hit => hit.GetProperty("entry").GetRawText()));
        string logical = second.Ok.Value.GetProperty("hits")[0].GetProperty("dict").GetString()!;
        Assert.Equal(dict, logical);
        Reply entry = client.Call("entry", new { dict = logical, entry = second.Ok.Value.GetProperty("hits")[0].GetProperty("entry"),
            view = new { baseUrl = "https://xdict.local/", maxBodyBytes = 1 << 20, originalStyle = false } });
        Assert.Null(entry.Error);
        Assert.NotEmpty(entry.Payload!);
    }

    [Fact]
    public async Task IdleExitRestartsOnDemand()
    {
        using var client = new ServiceClient(Environment.GetEnvironmentVariable("XDICT_SERVICE")!,
            new ServiceClientOptions { Storage = "idle-" + Guid.NewGuid().ToString("N"), Arguments = "--idle 1" });
        client.Handshake();
        int original = client.ProcessId;
        using var process = Process.GetProcessById(original);
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(3));
        Assert.NotNull(client.Handshake());
        Assert.NotEqual(original, client.ProcessId);
    }

    [Fact]
    public void ARenameOverAHeldHandleInvalidatesLookup()
    {
        string root = Path.Combine(Path.GetTempPath(), "xdict-source-" + Guid.NewGuid().ToString("N"));
        string moved = root + "-moved";
        Directory.CreateDirectory(root);
        string fixture = Path.Combine(root, "tiny.mdx");
        string generated = Path.Combine(Environment.GetEnvironmentVariable("XDICT_FIXTURES")!, "tiny", "tiny.mdx");
        File.Copy(generated, fixture);
        try
        {
            using var client = Start();
            object[] files = [client.Observe("tiny", "tiny", fixture)];
            var package = new { mdx = new { file = "tiny" } };
            Assert.Null(client.Call("import", new { package }, files).Error);
            string dict = client.Call("open", new { package }, files).Ok!.Value.GetProperty("dict").GetString()!;
            File.Move(fixture, fixture + ".held");
            File.Copy(generated, fixture);
            Reply changed = client.Call("lookup", new { query = "run", dicts = new[] { dict }, options = new { limit = 10, offset = 0, mode = "reader" } });
            Assert.Equal("sourceChanged", Error(changed));
        }
        finally
        {
            Directory.Delete(root, true);
            if (Directory.Exists(moved)) Directory.Delete(moved, true);
        }
    }

    [Fact]
    public async Task StalledBulkCallsAreKilledAndTheReopenedEntryCanBeRead()
    {
        using var client = new ServiceClient(Environment.GetEnvironmentVariable("XDICT_SERVICE")!, new ServiceClientOptions
        {
            Storage = "bulk-" + Guid.NewGuid().ToString("N"), BulkDeadline = TimeSpan.FromMilliseconds(400),
        });
        string fixture = Path.Combine(Environment.GetEnvironmentVariable("XDICT_FIXTURES")!, "tiny", "tiny.mdx");
        object[] files = [client.Observe("tiny", "tiny", fixture)];
        var package = new { mdx = new { file = "tiny" } };
        Assert.Null(client.Call("import", new { package }, files).Error);
        Reply opened = client.Call("open", new { package }, files);
        string dict = opened.Ok!.Value.GetProperty("dict").GetString()!;
        var body = new { dict, entry = new { edition = opened.Ok.Value.GetProperty("edition").GetString(), key = "run", occurrence = 0 },
            view = new { baseUrl = "https://xdict.local/", maxBodyBytes = 1 << 20, originalStyle = false } };
        using var process = Process.GetProcessById(client.ProcessId);
        Assert.Equal(0, NtSuspendProcess(process.SafeHandle));
        var replies = await Task.WhenAll(Enumerable.Range(0, 2).Select(_ => client.CallAsync("entry", body)))
            .WaitAsync(TimeSpan.FromSeconds(4));
        Assert.Contains(replies, reply => Error(reply) == "deadline");
        Assert.All(replies, reply => Assert.NotNull(reply.Error));
        Reply healthy = client.Call("entry", body);
        Assert.Null(healthy.Error);
        Assert.NotEmpty(healthy.Payload!);
    }

    [Fact]
    public async Task ACancelledStallStillReclaimsItsServiceCreditsAtTheDeadline()
    {
        using var client = Start(TimeSpan.FromMilliseconds(400));
        client.Handshake();
        using var process = Process.GetProcessById(client.ProcessId);
        Assert.Equal(0, NtSuspendProcess(process.SafeHandle));
        var sent = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        client.RequestSent += (_, _) => sent.TrySetResult();
        var call = client.CallAsync("versions", null, generation: client.NewGeneration("query"));
        await sent.Task.WaitAsync(TimeSpan.FromSeconds(2));
        _ = client.NewGeneration("query");
        Assert.Equal("cancelled", Error(await call));
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
        Assert.NotNull(client.Handshake());
    }
}

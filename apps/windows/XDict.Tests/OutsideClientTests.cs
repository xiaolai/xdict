using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using XDict.Client;
using Xunit;

public class OutsideClientTests
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetHandleInformation(SafeFileHandle handle, out uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DuplicateHandle(IntPtr sourceProcess, SafeFileHandle source, SafeProcessHandle targetProcess,
        out IntPtr target, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    private static async Task<int> Attempt(SafeFileHandle endpoint, bool grant)
    {
        var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("XDICT_OUTSIDE_CLIENT")!)
        {
            UseShellExecute = false, RedirectStandardInput = true,
        };
        start.ArgumentList.Add("--outside-handle");
        using var process = Process.Start(start)!;
        IntPtr candidate = endpoint.DangerousGetHandle();
        if (grant) Assert.True(DuplicateHandle(GetCurrentProcess(), endpoint, process.SafeHandle, out candidate, 0, false, 2));
        await process.StandardInput.WriteLineAsync(unchecked((ulong)candidate.ToInt64()).ToString(System.Globalization.CultureInfo.InvariantCulture));
        await process.StandardInput.FlushAsync();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(4));
        return process.ExitCode;
    }

    [Fact]
    public async Task AnOutsideExecutableNeedsAnExplicitEndpointGrant()
    {
        using var client = new ServiceClient(Environment.GetEnvironmentVariable("XDICT_SERVICE")!);
        client.Handshake();
        int original = client.ProcessId;
        Assert.True(GetHandleInformation(client.RequestPipe, out uint flags));
        Assert.Equal(0u, flags & 1);
        Assert.Equal(0, await Attempt(client.RequestPipe, grant: false));
        Assert.NotNull(client.Handshake());
        Assert.Equal(original, client.ProcessId);
        // Red-once control: explicitly granting the endpoint lets this same outside executable write a request.
        // This is a grant by the parent, not protection against a same-user program stealing handles (ADR-0022).
        Assert.Equal(1, await Attempt(client.RequestPipe, grant: true));
    }
}

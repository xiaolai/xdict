// The connection's own refusals come before any handle is duplicated into the service: a duplicate the service never
// receives is one nobody closes until the service exits.
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using XDict.Client;
using XDict.Contract;
using Xunit;

public class ServiceConnectionTests
{
    [DllImport("ntdll.dll")]
    private static extern int NtSuspendProcess(SafeProcessHandle process);
    [DllImport("ntdll.dll")]
    private static extern int NtResumeProcess(SafeProcessHandle process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DuplicateHandle(SafeProcessHandle sourceProcess, IntPtr source, IntPtr targetProcess,
        out IntPtr target, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    /// <summary>Whether <paramref name="handle"/> is open in <paramref name="process"/>: a copy of it can be taken.</summary>
    private static bool OpenIn(SafeProcessHandle process, ulong handle)
    {
        if (!DuplicateHandle(process, new IntPtr((long)handle), GetCurrentProcess(), out IntPtr copy, 0, false, 2)) return false;
        CloseHandle(copy);
        return true;
    }

    private static FileObservation Held(string id) => new(id, id, ulong.MaxValue, null, 0);

    private static ServiceConnection Start() =>
        new(Environment.GetEnvironmentVariable("XDICT_SERVICE")!, "test-" + Guid.NewGuid().ToString("N"), "");

    [Fact]
    public async Task AnOversizedRequestIsRefusedBeforeAnyHandleIsDuplicated()
    {
        using var connection = Start();
        int duplicated = 0;
        var body = new { query = new string('a', Wire.JsonMax) };
        await Assert.ThrowsAsync<ContractViolationException>(() => connection.Send(Wire.Version, 1, "lookup", body,
            Array.Empty<object>, files => { duplicated++; return files; }, () => { }, () => { }, CancellationToken.None));
        Assert.Equal(0, duplicated);
    }

    [Fact]
    public async Task AReusedIdIsRefusedBeforeAnyHandleIsDuplicated()
    {
        using var connection = Start();
        using var process = Process.GetProcessById(connection.Child.ProcessId);
        Assert.Equal(0, NtSuspendProcess(process.SafeHandle));
        try
        {
            var first = connection.Send(Wire.Version, 5, "versions", null, Array.Empty<object>, files => files, () => { },
                () => { }, CancellationToken.None);
            int duplicated = 0;
            await Assert.ThrowsAsync<ContractViolationException>(() => connection.Send(Wire.Version, 5, "versions", null,
                Array.Empty<object>, files => { duplicated++; return files; }, () => { }, () => { }, CancellationToken.None));
            Assert.Equal(0, duplicated);
            Assert.Equal(0, NtResumeProcess(process.SafeHandle));
            Assert.Null((await first.WaitAsync(TimeSpan.FromSeconds(5))).Error);
        }
        finally { _ = NtResumeProcess(process.SafeHandle); }
    }

    /// <summary>**A handle duplicated before a later file fails is closed in the service** (audit 2026-11-05): the
    /// request never reaches the service, so nothing there would ever close it.</summary>
    [Fact]
    public async Task AHandleDuplicatedBeforeALaterFileFailsIsClosedInTheService()
    {
        using var connection = Start();
        string path = Path.GetTempFileName();
        try
        {
            using SafeFileHandle file = Native.OpenFile(path);
            var handles = new ServiceHandles(connection.Child.ProcessHandle);
            ulong first = 0;
            IReadOnlyList<object> DuplicateTwo(IReadOnlyList<object> prepared)
            {
                first = handles.Duplicate(file);
                Assert.True(OpenIn(connection.Child.ProcessHandle, first), "the first file is in the service");
                throw new IOException("the second file could not be duplicated");
            }
            await Assert.ThrowsAsync<IOException>(() => connection.Send(Wire.Version, 7, "versions", null,
                () => new object[] { Held("a"), Held("b") }, DuplicateTwo, () => { }, handles.Release,
                CancellationToken.None));
            Assert.NotEqual(0UL, first);
            Assert.False(OpenIn(connection.Child.ProcessHandle, first), "the first file's handle was left in the service");
        }
        finally { File.Delete(path); }
    }

    /// <summary>**A request whose frame cannot be written takes its handles back**: the service that stopped reading
    /// never receives them.</summary>
    [Fact]
    public async Task HandlesOfARequestThatCannotBeWrittenAreReleased()
    {
        using var connection = Start();
        int released = 0;
        IReadOnlyList<object> StopTheService(IReadOnlyList<object> prepared)
        {
            using var process = Process.GetProcessById(connection.Child.ProcessId);
            process.Kill();
            process.WaitForExit();
            return prepared;
        }
        await Assert.ThrowsAnyAsync<IOException>(() => connection.Send(Wire.Version, 9, "versions", null,
            Array.Empty<object>, StopTheService, () => { }, () => released++, CancellationToken.None));
        Assert.Equal(1, released);
    }
}

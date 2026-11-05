// One confined CLI child: the prompt on stdin, a job object that kills it and its descendants when this object closes,
// no shell and no inherited reader configuration. The child's output is its own; a non-zero status is typed.
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace XDict.AI;

[SupportedOSPlatform("windows")]
public sealed class AIProcess : IDisposable
{
    private const uint JobObjectExtendedLimitInformation = 9;
    private const uint KillOnJobClose = 0x2000;
    private IntPtr job;
    private bool disposed;

    public AIProcess(string executable, IReadOnlyList<string> arguments, string workingDirectory,
        IReadOnlyDictionary<string, string> environment)
    {
        if (!OperatingSystem.IsWindows()) throw new AIProviderException(AIProviderError.NotConfigured);
        job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new AIProviderException(AIProviderError.NotConfigured, "job object");
        var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION { LimitFlags = KillOnJobClose },
        };
        IntPtr buffer = Marshal.AllocHGlobal(Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>());
        try
        {
            Marshal.StructureToPtr(limits, buffer, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer,
                    (uint)Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>()))
            {
                CloseHandle(job);
                job = IntPtr.Zero;
                throw new AIProviderException(AIProviderError.NotConfigured, "job limits");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
        var info = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (string argument in arguments) info.ArgumentList.Add(argument);
        foreach ((string key, string value) in environment) info.Environment[key] = value;
        try
        {
            Process = Process.Start(info) ?? throw new AIProviderException(AIProviderError.NotConfigured);
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or FileNotFoundException)
        {
            Dispose();
            throw new AIProviderException(AIProviderError.NotConfigured, error.Message);
        }
        if (!AssignProcessToJobObject(job, Process.Handle))
        {
            Kill();
            throw new AIProviderException(AIProviderError.NotConfigured, "the CLI could not be confined");
        }
    }

    public Process Process { get; } = null!;

    public async Task<string> RunAsync(string stdio, TimeSpan timeout, CancellationToken cancellation = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        try
        {
            Task<string> stdout = Process.StandardOutput.ReadToEndAsync(CancellationToken.None);
            Task<string> stderr = Process.StandardError.ReadToEndAsync(CancellationToken.None);
            await Process.StandardInput.WriteAsync(stdio).ConfigureAwait(false);
            Process.StandardInput.Close();
            using var clock = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            clock.CancelAfter(timeout);
            try
            {
                await Process.WaitForExitAsync(clock.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
            {
                Kill();
                throw new AIProviderException(AIProviderError.Timeout);
            }
            catch (OperationCanceledException)
            {
                Kill();
                throw;
            }
            string output = await stdout.ConfigureAwait(false);
            string errors = await stderr.ConfigureAwait(false);
            if (Process.ExitCode != 0)
                throw new AIProviderException(AIProviderError.CliFailed, Collapse(errors + "\n" + output));
            return output;
        }
        finally
        {
            // The job is closed here on every path: kill-on-close leaves no orphan if the parent dies after this.
            Kill();
        }
    }

    private static string Collapse(string text)
    {
        string single = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return single.Length <= 300 ? single : single[..300];
    }

    private void Kill()
    {
        if (job != IntPtr.Zero)
        {
            TerminateJobObject(job, 1);
            CloseHandle(job);
            job = IntPtr.Zero;
        }
        try
        {
            if (Process is { HasExited: false }) Process.Kill(entireProcessTree: true);
        }
        catch (Exception) { }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        Kill();
        Process?.Dispose();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObjectW(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, uint infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}

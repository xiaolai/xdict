// One confined CLI child: the prompt on stdin, a job object that kills it and its descendants when this object closes,
// no shell and no inherited reader configuration. The child's output is its own; a non-zero status is typed.
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32.SafeHandles;

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
        // CreateProcessW does not search PATH for lpApplicationName, unlike Process.Start: a bare name is resolved
        // here, against the app's own PATH, before anything is created.
        executable = Resolve(executable);
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
        // **Suspended until it is in the job.** A process started normally runs before assignment, and anything it
        // spawns in that window is outside the job and survives this object. The child is created suspended, assigned,
        // then resumed; nothing of it runs unconfined.
        IntPtr inRead = IntPtr.Zero, inWrite = IntPtr.Zero;
        IntPtr outRead = IntPtr.Zero, outWrite = IntPtr.Zero;
        IntPtr errRead = IntPtr.Zero, errWrite = IntPtr.Zero;
        PROCESS_INFORMATION created = default;
        IntPtr list = IntPtr.Zero, handles = IntPtr.Zero;
        var owned = new List<IntPtr>();
        try
        {
            var inheritable = new SECURITY_ATTRIBUTES
            {
                Length = Marshal.SizeOf<SECURITY_ATTRIBUTES>(),
                InheritHandle = 1,
            };
            if (!CreatePipe(out inRead, out inWrite, ref inheritable, 0)) throw Failure("CreatePipe");
            owned.Add(inRead);
            owned.Add(inWrite);
            if (!CreatePipe(out outRead, out outWrite, ref inheritable, 0)) throw Failure("CreatePipe");
            owned.Add(outRead);
            owned.Add(outWrite);
            if (!CreatePipe(out errRead, out errWrite, ref inheritable, 0)) throw Failure("CreatePipe");
            owned.Add(errRead);
            owned.Add(errWrite);
            foreach (IntPtr parentEnd in new[] { inWrite, outRead, errRead })
                if (!SetHandleInformation(parentEnd, 1, 0)) throw Failure("clear parent handle inheritance");

            // The child inherits exactly these three ends, never whatever else this process has marked inheritable:
            // the handle list is the same discipline the service's own spawn uses.
            IntPtr listSize = IntPtr.Zero;
            _ = InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref listSize);
            list = Marshal.AllocHGlobal(listSize);
            if (!InitializeProcThreadAttributeList(list, 1, 0, ref listSize))
                throw Failure("InitializeProcThreadAttributeList");
            handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
            Marshal.WriteIntPtr(handles, 0, inRead);
            Marshal.WriteIntPtr(handles, IntPtr.Size, outWrite);
            Marshal.WriteIntPtr(handles, IntPtr.Size * 2, errWrite);
            if (!UpdateProcThreadAttribute(list, 0, ProcThreadAttributeHandleList, handles,
                    (IntPtr)(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                throw Failure("UpdateProcThreadAttribute");
            // The block holds exactly the filtered dictionary: starting from null would copy this process's whole
            // environment, keys the allowlist exists to withhold included.
            IntPtr block = Marshal.StringToHGlobalUni(Block(environment));
            try
            {
                var startup = new STARTUPINFOEX
                {
                    Startup = new STARTUPINFO
                    {
                        Size = Marshal.SizeOf<STARTUPINFOEX>(),
                        Flags = (int)StartfUseStdHandles,
                        StandardInput = inRead,
                        StandardOutput = outWrite,
                        StandardError = errWrite,
                    },
                    AttributeList = list,
                };
                var command = new StringBuilder(CommandLine(executable, arguments));
                if (!CreateProcessW(executable, command, IntPtr.Zero, IntPtr.Zero, inheritHandles: true,
                        CreateSuspended | CreateNoWindow | CreateUnicodeEnvironment | ExtendedStartupInfoPresent,
                        block, workingDirectory, ref startup, out created))
                    throw Failure("CreateProcessW");
            }
            finally
            {
                Marshal.FreeHGlobal(block);
            }
            foreach (IntPtr childEnd in new[] { inRead, outWrite, errWrite })
            {
                CloseHandle(childEnd);
                owned.Remove(childEnd);
            }
            // GetProcessById while the child is suspended: the handle below keeps the process object alive, so a
            // process that exits the instant it resumes still has a Process to wait on and read the status from.
            Process = System.Diagnostics.Process.GetProcessById(created.ProcessId);
            process = new SafeProcessHandle(created.Process, ownsHandle: true);
            created.Process = IntPtr.Zero;
            if (!AssignProcessToJobObject(job, process.DangerousGetHandle()))
                throw new AIProviderException(AIProviderError.NotConfigured, "the CLI could not be confined");
            if (ResumeThread(created.Thread) == uint.MaxValue) throw Failure("ResumeThread");
            StandardInput = new FileStream(new SafeFileHandle(inWrite, ownsHandle: true), FileAccess.Write);
            owned.Remove(inWrite);
            StandardOutput = new StreamReader(new FileStream(new SafeFileHandle(outRead, ownsHandle: true), FileAccess.Read));
            owned.Remove(outRead);
            StandardError = new StreamReader(new FileStream(new SafeFileHandle(errRead, ownsHandle: true), FileAccess.Read));
            owned.Remove(errRead);
        }
        catch (Exception error)
        {
            foreach (IntPtr handle in owned) CloseHandle(handle);
            if (created.Process != IntPtr.Zero) CloseHandle(created.Process);
            Kill();
            Process?.Dispose();
            process?.Dispose();
            process = null;
            throw error is AIProviderException
                ? error
                : new AIProviderException(AIProviderError.NotConfigured, error.Message);
        }
        finally
        {
            if (created.Thread != IntPtr.Zero) CloseHandle(created.Thread);
            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
            if (list != IntPtr.Zero)
            {
                DeleteProcThreadAttributeList(list);
                Marshal.FreeHGlobal(list);
            }
        }
    }

    private SafeProcessHandle? process;

    public Process Process { get; private set; } = null!;

    public Stream StandardInput { get; } = Stream.Null;
    public StreamReader StandardOutput { get; } = System.IO.StreamReader.Null;
    public StreamReader StandardError { get; } = System.IO.StreamReader.Null;

    public async Task<string> RunAsync(string stdio, TimeSpan timeout, CancellationToken cancellation = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        // One deadline covers the write, the wait and both drains: a child that stops reading stdin, or that leaves
        // a descendant holding stdout after it exits, would otherwise hang here forever.
        using var clock = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        clock.CancelAfter(timeout);
        try
        {
            Task<string> stdout = ReadCappedAsync(StandardOutput, OutputCap, clock.Token);
            Task<string> stderr = ReadCappedAsync(StandardError, OutputCap, clock.Token);
            byte[] prompt = Encoding.UTF8.GetBytes(stdio);
            await StandardInput.WriteAsync(prompt, clock.Token).ConfigureAwait(false);
            StandardInput.Close();
            await Process.WaitForExitAsync(clock.Token).ConfigureAwait(false);
            string output = await stdout.ConfigureAwait(false);
            string errors = await stderr.ConfigureAwait(false);
            if (Process.ExitCode != 0)
                throw new AIProviderException(AIProviderError.CliFailed, Collapse(errors + "\n" + output));
            return output;
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
        finally
        {
            // The job is closed here on every path: kill-on-close leaves no orphan if the parent dies after this.
            Kill();
        }
    }

    private const int OutputCap = 1 << 20;

    /// <summary>Reads a redirected stream with a fixed ceiling; the error message is truncated later, but the
    /// allocation is what a runaway CLI would grow without bound.</summary>
    private static async Task<string> ReadCappedAsync(StreamReader reader, int cap, CancellationToken cancellation)
    {
        var buffer = new char[16 * 1024];
        var text = new System.Text.StringBuilder();
        while (true)
        {
            int read = await reader.ReadAsync(buffer.AsMemory(), cancellation).ConfigureAwait(false);
            if (read == 0) return text.ToString();
            if (text.Length + read > cap)
                throw new AIProviderException(AIProviderError.CliFailed, "the CLI wrote more output than a reader can use");
            text.Append(buffer, 0, read);
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
        foreach (Stream stream in new[] { StandardInput, StandardOutput.BaseStream, StandardError.BaseStream })
        {
            try { stream.Dispose(); }
            catch (IOException) { }
        }
        Process?.Dispose();
        process?.Dispose();
        process = null;
    }

    private const uint CreateSuspended = 0x00000004;
    private const uint CreateNoWindow = 0x08000000;
    private const uint CreateUnicodeEnvironment = 0x00000400;
    private const uint ExtendedStartupInfoPresent = 0x00080000;
    private const uint StartfUseStdHandles = 0x00000100;

    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES
    {
        public int Length;
        public IntPtr Descriptor;
        public int InheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int Size;
        public IntPtr Reserved;
        public IntPtr Desktop;
        public IntPtr Title;
        public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public short ShowWindow, Reserved2Size;
        public IntPtr Reserved2;
        public IntPtr StandardInput, StandardOutput, StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFO Startup;
        public IntPtr AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr Process;
        public IntPtr Thread;
        public int ProcessId;
        public int ThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SECURITY_ATTRIBUTES attributes,
        uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(string? application, StringBuilder commandLine, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string? currentDirectory,
        ref STARTUPINFOEX startup, out PROCESS_INFORMATION process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    private static readonly IntPtr ProcThreadAttributeHandleList = new(0x00020002);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value,
        IntPtr size, IntPtr previous, IntPtr returned);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr list);

    private static Win32Exception Failure(string call)
    {
        int error = Marshal.GetLastWin32Error();
        return new Win32Exception(error, call + " failed (Win32 " + error + ")");
    }

    /// <summary>A bare executable name resolved against this process's PATH; a full path is kept as given.</summary>
    private static string Resolve(string executable)
    {
        if (string.IsNullOrWhiteSpace(executable))
            throw new AIProviderException(AIProviderError.NotConfigured, "no executable");
        if (Path.IsPathFullyQualified(executable)) return executable;
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                string candidate = Path.Combine(directory.Trim('"'), executable);
                if (File.Exists(candidate)) return candidate;
            }
            catch (Exception error) when (error is ArgumentException or NotSupportedException) { }
        }
        throw new AIProviderException(AIProviderError.NotConfigured, executable + " was not found on PATH");
    }

    /// <summary>The double-null-terminated block holding exactly the named environment, sorted as Windows requires.</summary>
    private static string Block(IReadOnlyDictionary<string, string> environment)
    {
        var text = new StringBuilder();
        foreach ((string key, string value) in environment.OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase))
            text.Append(key).Append('=').Append(value).Append('\0');
        text.Append('\0');
        return text.ToString();
    }

    /// <summary>The command line CreateProcessW takes: argv quoting, not a shell's. An argument with a space or a quote
    /// is wrapped and its backslashes doubled where they precede a quote, so the child's parser sees them unchanged.</summary>
    private static string CommandLine(string executable, IReadOnlyList<string> arguments)
    {
        var command = new StringBuilder();
        AppendArgument(command, executable);
        foreach (string argument in arguments) AppendArgument(command, argument);
        return command.ToString();
    }

    private static void AppendArgument(StringBuilder command, string argument)
    {
        if (command.Length > 0) command.Append(' ');
        if (argument.Length > 0 && !argument.Any(c => c is ' ' or '\t' or '"')) { command.Append(argument); return; }
        command.Append('"');
        for (int i = 0; i < argument.Length; i++)
        {
            int backslashes = 0;
            while (i < argument.Length && argument[i] == '\\') { i++; backslashes++; }
            if (i == argument.Length) { command.Append('\\', backslashes * 2); break; }
            if (argument[i] == '"') command.Append('\\', backslashes * 2 + 1).Append('"');
            else command.Append('\\', backslashes).Append(argument[i]);
        }
        command.Append('"');
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

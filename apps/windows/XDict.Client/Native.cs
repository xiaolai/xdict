// The production spawn (CONTRACT.md §1): three private pipes, and only their child ends inherited, through
// PROC_THREAD_ATTRIBUTE_HANDLE_LIST. There is no name to connect to and no listener; a reconnect is a new process and
// a new set of pipes. The app's own end of each pipe stays in this process.
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using XDict.Contract;

namespace XDict.Client;

internal static class Native
{
    internal const int StartfUseStdHandles = 0x00000100;
    internal const uint ExtendedStartupInfoPresent = 0x00080000;
    internal const uint CreateNoWindow = 0x08000000;
    internal const uint CreateUnicodeEnvironment = 0x00000400;

    private static readonly IntPtr ProcThreadAttributeHandleList = new(0x00020002);

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Length;
        public IntPtr Descriptor;
        public int InheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int Size;
        public IntPtr Reserved;
        public IntPtr Desktop;
        public IntPtr Title;
        public int X;
        public int Y;
        public int XSize;
        public int YSize;
        public int XCountChars;
        public int YCountChars;
        public int FillAttribute;
        public int Flags;
        public ushort ShowWindow;
        public ushort Reserved2Size;
        public IntPtr Reserved2;
        public IntPtr StandardInput;
        public IntPtr StandardOutput;
        public IntPtr StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx
    {
        public StartupInfo Startup;
        public IntPtr AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr Process;
        public IntPtr Thread;
        public int ProcessId;
        public int ThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SecurityAttributes attributes, uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void DeleteProcThreadAttributeList(IntPtr list);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(
        string? application, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint flags, IntPtr environment, string? currentDirectory,
        ref StartupInfoEx startup, out ProcessInformation process);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool TerminateProcess(SafeProcessHandle process, uint exitCode);

    private const uint FileReadAttributes = 0x0080;
    private const uint GenericRead = 0x80000000;
    private const uint ShareAll = 0x00000007;
    private const uint OpenExisting = 3;
    private const uint FileAttributeNormal = 0x80;
    private const uint DuplicateSameAccess = 0x00000002;

    [StructLayout(LayoutKind.Sequential)]
    private struct FileBasicInfo
    {
        public long Creation;
        public long Access;
        public long Write;
        public long Change;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileStandardInfo
    {
        public long Allocation;
        public long EndOfFile;
        public uint Links;
        public byte DeletePending;
        public byte Directory;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdInfo
    {
        public ulong Volume;
        public ulong Low;
        public ulong High;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFileW(
        string name, uint access, uint share, IntPtr attributes, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DuplicateHandle(
        IntPtr sourceProcess, SafeFileHandle source, SafeProcessHandle targetProcess, out IntPtr target,
        uint access, bool inherit, uint options);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int infoClass, IntPtr info, uint size);

    /// <summary>The identity of whatever is at <paramref name="path"/> now, or null when nothing is.</summary>
    internal static FileIdentity? ObservePath(string path)
    {
        using SafeFileHandle file = CreateFileW(
            path, FileReadAttributes, ShareAll, IntPtr.Zero, OpenExisting, FileAttributeNormal, IntPtr.Zero);
        return file.IsInvalid ? null : IdentityOf(file);
    }

    /// <summary>Opens the file read-only and duplicates the handle into the service process; the duplicate's value.</summary>
    internal static ulong DuplicateFile(SafeProcessHandle service, string path)
    {
        using SafeFileHandle file = OpenFile(path);
        return DuplicateFile(service, file);
    }

    internal static SafeFileHandle OpenFile(string path)
    {
        SafeFileHandle file = CreateFileW(path, GenericRead, ShareAll, IntPtr.Zero, OpenExisting, FileAttributeNormal, IntPtr.Zero);
        if (file.IsInvalid) { file.Dispose(); throw Failure("open dictionary file"); }
        return file;
    }

    internal static ulong DuplicateFile(SafeProcessHandle service, SafeFileHandle file)
    {
        if (!DuplicateHandle(GetCurrentProcess(), file, service, out IntPtr duplicated, 0, false, DuplicateSameAccess))
            throw Failure("duplicate dictionary handle");
        return (ulong)duplicated.ToInt64();
    }

    private static FileIdentity? IdentityOf(SafeFileHandle file)
    {
        int basicSize = Marshal.SizeOf<FileBasicInfo>();
        int standardSize = Marshal.SizeOf<FileStandardInfo>();
        int idSize = Marshal.SizeOf<FileIdInfo>();
        IntPtr basic = Marshal.AllocHGlobal(basicSize);
        IntPtr standard = Marshal.AllocHGlobal(standardSize);
        IntPtr id = Marshal.AllocHGlobal(idSize);
        try
        {
            if (!GetFileInformationByHandleEx(file, 0, basic, (uint)basicSize)) return null;
            if (!GetFileInformationByHandleEx(file, 1, standard, (uint)standardSize)) return null;
            if (!GetFileInformationByHandleEx(file, 18, id, (uint)idSize)) return null;
            FileBasicInfo basicInfo = Marshal.PtrToStructure<FileBasicInfo>(basic);
            FileStandardInfo standardInfo = Marshal.PtrToStructure<FileStandardInfo>(standard);
            FileIdInfo idInfo = Marshal.PtrToStructure<FileIdInfo>(id);
            return new FileIdentity(
                idInfo.Volume, idInfo.Low, (ulong)Math.Max(0, standardInfo.EndOfFile),
                ToUnixNs(basicInfo.Write), ToUnixNs(basicInfo.Change));
        }
        finally
        {
            Marshal.FreeHGlobal(basic);
            Marshal.FreeHGlobal(standard);
            Marshal.FreeHGlobal(id);
        }
    }

    private static long ToUnixNs(long fileTime)
    {
        const long epoch = 116_444_736_000_000_000;
        try
        {
            return checked((fileTime - epoch) * 100);
        }
        catch (OverflowException)
        {
            return fileTime > epoch ? long.MaxValue : long.MinValue;
        }
    }

    internal static ChildProcess Spawn(string executable, string storage = "service", string arguments = "")
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("XDict's service requires Windows");
        if (!File.Exists(executable))
            throw new FileNotFoundException("the service is not at " + executable, executable);
        if (storage.Length == 0 || storage.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-'))
            throw new ArgumentException("storage must be a single ASCII name", nameof(storage));
        using var container = new AppContainer(executable);

        var inheritable = new SecurityAttributes
        {
            Length = Marshal.SizeOf<SecurityAttributes>(),
            InheritHandle = 1,
        };

        IntPtr requestRead = IntPtr.Zero, requestWrite = IntPtr.Zero;
        IntPtr replyRead = IntPtr.Zero, replyWrite = IntPtr.Zero;
        IntPtr errorRead = IntPtr.Zero, errorWrite = IntPtr.Zero;
        var owned = new List<IntPtr>();
        IntPtr list = IntPtr.Zero, handles = IntPtr.Zero;
        ProcessInformation process = default;
        try
        {
            if (!CreatePipe(out requestRead, out requestWrite, ref inheritable, 0)) throw Failure("CreatePipe");
            owned.Add(requestRead);
            owned.Add(requestWrite);
            if (!CreatePipe(out replyRead, out replyWrite, ref inheritable, 0)) throw Failure("CreatePipe");
            owned.Add(replyRead);
            owned.Add(replyWrite);
            if (!CreatePipe(out errorRead, out errorWrite, ref inheritable, 0)) throw Failure("CreatePipe");
            owned.Add(errorRead);
            owned.Add(errorWrite);
            foreach (IntPtr parentEnd in new[] { requestWrite, replyRead, errorRead })
                if (!SetHandleInformation(parentEnd, 1, 0)) throw Failure("clear parent handle inheritance");

            IntPtr size = IntPtr.Zero;
            // The first call sizes the list and is expected to fail with ERROR_INSUFFICIENT_BUFFER.
            _ = InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
            list = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(list, 2, 0, ref size)) throw Failure("InitializeProcThreadAttributeList");
            if (!UpdateProcThreadAttribute(list, 0, new IntPtr(0x00020009), container.Capabilities,
                    (IntPtr)AppContainer.CapabilitiesSize, IntPtr.Zero, IntPtr.Zero))
                throw Failure("AppContainer security capabilities");
            handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
            Marshal.WriteIntPtr(handles, 0, requestRead);
            Marshal.WriteIntPtr(handles, IntPtr.Size, replyWrite);
            Marshal.WriteIntPtr(handles, IntPtr.Size * 2, errorWrite);
            if (!UpdateProcThreadAttribute(
                    list, 0, ProcThreadAttributeHandleList, handles, (IntPtr)(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                throw Failure("UpdateProcThreadAttribute");

            var startup = new StartupInfoEx
            {
                Startup = new StartupInfo
                {
                    Size = Marshal.SizeOf<StartupInfoEx>(),
                    Flags = StartfUseStdHandles,
                    StandardInput = requestRead,
                    StandardOutput = replyWrite,
                    StandardError = errorWrite,
                },
                AttributeList = list,
            };
            string root = Path.Combine(container.Folder, storage);
            var commandLine = new StringBuilder($"\"{executable}\" --data \"{Path.Combine(root, "data")}\" --cache \"{Path.Combine(root, "cache")}\" {arguments}");
            if (!CreateProcessW(
                    executable, commandLine, IntPtr.Zero, IntPtr.Zero, inheritHandles: true,
                    ExtendedStartupInfoPresent | CreateNoWindow | CreateUnicodeEnvironment,
                    IntPtr.Zero, container.Folder, ref startup, out process))
                throw Failure("CreateProcessW");

            CloseHandle(process.Thread);
            process.Thread = IntPtr.Zero;
            foreach (IntPtr childEnd in new[] { requestRead, replyWrite, errorWrite })
            {
                CloseHandle(childEnd);
                owned.Remove(childEnd);
            }

            FileStream? input = null, output = null, errors = null;
            try
            {
                input = Own(requestWrite, FileAccess.Write);
                owned.Remove(requestWrite);
                output = Own(replyRead, FileAccess.Read);
                owned.Remove(replyRead);
                errors = Own(errorRead, FileAccess.Read);
                owned.Remove(errorRead);
                return new ChildProcess(
                    input, output, errors, new SafeProcessHandle(process.Process, ownsHandle: true), process.ProcessId);
            }
            catch
            {
                input?.Dispose();
                output?.Dispose();
                errors?.Dispose();
                throw;
            }
        }
        catch
        {
            if (process.Process != IntPtr.Zero)
            {
                CloseHandle(process.Process);
                if (process.Thread != IntPtr.Zero) CloseHandle(process.Thread);
            process.Thread = IntPtr.Zero;
            }
            foreach (IntPtr handle in owned) CloseHandle(handle);
            throw;
        }
        finally
        {
            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
            if (list != IntPtr.Zero)
            {
                DeleteProcThreadAttributeList(list);
                Marshal.FreeHGlobal(list);
            }
        }
    }

    private static FileStream Own(IntPtr handle, FileAccess access)
    {
        var safe = new SafeFileHandle(handle, ownsHandle: true);
        try
        {
            return new FileStream(safe, access);
        }
        catch
        {
            safe.Dispose();
            throw;
        }
    }

    private static Win32Exception Failure(string call)
    {
        int error = Marshal.GetLastWin32Error();
        return new Win32Exception(error, call + " failed (Win32 " + error + ")");
    }
}

/// <summary>The spawned service and this process's ends of its three pipes.</summary>
internal sealed class ChildProcess(
    Stream input, Stream output, Stream errors, SafeProcessHandle process, int processId) : IDisposable
{
    public Stream Input { get; } = input;

    public Stream Output { get; } = output;

    public Stream Errors { get; } = errors;

    public int ProcessId { get; } = processId;

    public SafeProcessHandle ProcessHandle => process;

    private int disposed;

    public void Abort()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        _ = Native.TerminateProcess(process, 1);
        _ = Native.WaitForSingleObject(process, 2000);
        ClosePipe(Input);
        ClosePipe(Output);
        ClosePipe(Errors);
        process.Dispose();
    }

    private static void ClosePipe(Stream stream)
    {
        // A killed reader can leave buffered bytes in the pipe writer; disposal must not replace the typed error.
        try { stream.Dispose(); }
        catch (IOException) { }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        try
        {
            Input.Dispose();
        }
        catch (IOException)
        {
        }
        if (Native.WaitForSingleObject(process, 2000) != 0)
        {
            _ = Native.TerminateProcess(process, 1);
            _ = Native.WaitForSingleObject(process, 2000);
        }
        Output.Dispose();
        Errors.Dispose();
        process.Dispose();
    }
}

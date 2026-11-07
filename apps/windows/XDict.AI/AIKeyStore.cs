// The reader's one HTTP key, kept where macOS keeps its Keychain item: Windows Credential Manager, never a settings
// file. Reading returns null for a missing or unreadable item; writing null deletes it. The key never enters a log.
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace XDict.AI;

public interface IAIKeyStore
{
    string? Read();
    void Write(string? key);
}

[SupportedOSPlatform("windows")]
public sealed class WindowsCredentialStore(string target = "XDict.AI.http") : IAIKeyStore
{
    private const uint CredentialTypeGeneric = 1;
    private const uint CredentialPersistLocalMachine = 2;

    public string? Read()
    {
        if (!CredReadW(target, CredentialTypeGeneric, 0, out IntPtr pointer) || pointer == IntPtr.Zero) return null;
        try
        {
            CREDENTIAL credential = Marshal.PtrToStructure<CREDENTIAL>(pointer);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0) return null;
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes);
        }
        finally
        {
            CredFree(pointer);
        }
    }

    public void Write(string? key)
    {
        if (string.IsNullOrEmpty(key))
        {
            // Not there is the desired state; any other refusal must reach the reader, or a removal that failed
            // would be reported as one that worked.
            if (!CredDeleteW(target, CredentialTypeGeneric, 0))
            {
                const int ErrorNotFound = 1168;
                int error = Marshal.GetLastWin32Error();
                if (error != ErrorNotFound)
                    throw new AIProviderException(AIProviderError.NotConfigured,
                        "the saved key could not be removed (Win32 " + error + ")");
            }
            return;
        }
        byte[] bytes = Encoding.UTF8.GetBytes(key);
        IntPtr blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new CREDENTIAL
            {
                Type = CredentialTypeGeneric,
                TargetName = target,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = CredentialPersistLocalMachine,
                UserName = "XDict",
            };
            if (!CredWriteW(ref credential, 0))
                throw new AIProviderException(AIProviderError.NotConfigured, "the key could not be saved");
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string? TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] public string? Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)] public string? TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] public string? UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}

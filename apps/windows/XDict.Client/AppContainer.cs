// Capability-free parser sandbox. Only the service executable receives an RX grant; dictionary files never do.
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;

namespace XDict.Client;

[SupportedOSPlatform("windows")]
internal sealed class AppContainer : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityCapabilities
    {
        public IntPtr Sid;
        public IntPtr Capabilities;
        public uint Count;
        public uint Reserved;
    }

    [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
    private static extern int CreateAppContainerProfile(string name, string display, string description,
        IntPtr capabilities, uint count, out IntPtr sid);
    [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
    private static extern int DeriveAppContainerSidFromAppContainerName(string name, out IntPtr sid);
    [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
    private static extern int GetAppContainerFolderPath(string sid, out IntPtr folder);
    [DllImport("advapi32.dll")]
    private static extern IntPtr FreeSid(IntPtr sid);

    private IntPtr sid;
    private static readonly object SetupGate = new();
    public IntPtr Capabilities { get; private set; }
    public string Folder { get; }

    public AppContainer(string executable)
    {
        const string name = "ai.xdict.app.DictionaryService";
        lock (SetupGate)
        {
            // Creating a profile already in use can return E_UNEXPECTED, not just ALREADY_EXISTS.
            // Derive first, and create only if its folder does not exist.
            Marshal.ThrowExceptionForHR(DeriveAppContainerSidFromAppContainerName(name, out sid));
            string folder = FolderFor(sid);
            if (!Directory.Exists(folder))
            {
                FreeSid(sid);
                sid = IntPtr.Zero;
                int created = CreateAppContainerProfile(name, "XDict Dictionary Service", "XDict parser sandbox", IntPtr.Zero, 0, out sid);
                if (created == unchecked((int)0x800700B7))
                    created = DeriveAppContainerSidFromAppContainerName(name, out sid);
                Marshal.ThrowExceptionForHR(created);
            }
        }
        try
        {
            var principal = new SecurityIdentifier(sid);
            Folder = FolderFor(sid);

            var file = new FileInfo(executable);
            lock (SetupGate)
            {
                FileSecurity acl = file.GetAccessControl();
                bool granted = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).OfType<FileSystemAccessRule>()
                    .Any(rule => rule.IdentityReference.Equals(principal) && rule.AccessControlType == AccessControlType.Allow &&
                        (rule.FileSystemRights & FileSystemRights.ReadAndExecute) == FileSystemRights.ReadAndExecute);
                if (!granted)
                {
                    acl.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.ReadAndExecute, AccessControlType.Allow));
                    file.SetAccessControl(acl);
                }
            }
            Capabilities = Marshal.AllocHGlobal(Marshal.SizeOf<SecurityCapabilities>());
            Marshal.StructureToPtr(new SecurityCapabilities { Sid = sid }, Capabilities, false);
        }
        catch { Dispose(); throw; }
    }

    public static int CapabilitiesSize => Marshal.SizeOf<SecurityCapabilities>();

    private static string FolderFor(IntPtr sid)
    {
        int result = GetAppContainerFolderPath(new SecurityIdentifier(sid).Value, out IntPtr folder);
        Marshal.ThrowExceptionForHR(result);
        try { return Marshal.PtrToStringUni(folder) ?? throw new Win32Exception("no AppContainer folder"); }
        finally { Marshal.FreeCoTaskMem(folder); }
    }

    public void Dispose()
    {
        if (Capabilities != IntPtr.Zero) Marshal.FreeHGlobal(Capabilities);
        if (sid != IntPtr.Zero) FreeSid(sid);
        Capabilities = IntPtr.Zero;
        sid = IntPtr.Zero;
    }
}

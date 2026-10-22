// The Win32 surface capture needs: a message-only window, a global hotkey, the tray icon, window styles and placement,
// the low-level hooks the panel uses to dismiss itself, and the elevation probe that refuses a UIPI dead zone with a
// sentence. Hand-written and few, as the spike's record argues: these entry points are stable and reviewable by eye.
using System.Runtime.InteropServices;
using System.Collections.Generic;

namespace XDict.App.Capture;

internal static partial class Win32
{
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public static readonly IntPtr HWND_MESSAGE = new(-3);
    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;

    public const int WM_HOTKEY = 0x0312;
    public const int WM_APP = 0x8000;
    public const int WM_KEYDOWN = 0x0100;
    public const int WM_LBUTTONDOWN = 0x0201;
    public const int WM_RBUTTONDOWN = 0x0204;
    public const int WH_KEYBOARD_LL = 13;
    public const int WH_MOUSE_LL = 14;
    public const int VK_ESCAPE = 0x1B;

    public const uint MOD_ALT = 0x0001, MOD_CONTROL = 0x0002, MOD_SHIFT = 0x0004;
    public const uint MOD_NOREPEAT = 0x4000;

    public const uint NIM_ADD = 0, NIM_DELETE = 2;
    public const uint NIF_MESSAGE = 0x01, NIF_ICON = 0x02, NIF_TIP = 0x04;
    public const uint TPM_RETURNCMD = 0x0100, TPM_NONOTIFY = 0x0080;
    public const uint MF_STRING = 0x0000, MF_SEPARATOR = 0x0800;

    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    public const uint TOKEN_QUERY = 0x0008;
    public const int TokenElevation = 20;

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO { public uint cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }

    public const uint MONITOR_DEFAULTTONEAREST = 2;

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromRect(ref RECT rect, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFO info);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NOTIFYICONDATA
    {
        public int cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uTimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_ELEVATION { public int TokenIsElevated; }

    public delegate IntPtr WndProc(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
    public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateWindowExW(uint exStyle, string className, string windowName, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr DefWindowProcW(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowLongPtrW(IntPtr hWnd, int index, IntPtr value);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindowLongPtrW(IntPtr hWnd, int index);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookExW(int hook, HookProc proc, IntPtr module, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandleW(string? name);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern bool Shell_NotifyIconW(uint message, ref NOTIFYICONDATA data);

    [DllImport("user32.dll")]
    public static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool AppendMenuW(IntPtr menu, uint flags, nuint item, string text);

    [DllImport("user32.dll")]
    public static extern int TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr hWnd, IntPtr rect);

    [DllImport("user32.dll")]
    public static extern bool DestroyMenu(IntPtr menu);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint attach, uint attachTo, bool join);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);

    [DllImport("user32.dll")]
    public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, [Out] char[] name, int size);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr parameter);

    /// <summary>Every visible top-level window a process owns.</summary>
    public static IntPtr[] TopLevelWindowsOf(uint processId)
    {
        var windows = new List<IntPtr>();
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out uint owner);
            if (owner == processId && IsWindowVisible(window)) windows.Add(window);
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }

    /// <summary>The visible top-level window of `processId` whose class is `className`; 0 where there is none.</summary>
    public static IntPtr WindowOfClass(uint processId, string className)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out uint owner);
            if (owner != processId || !IsWindowVisible(window)) return true;
            var name = new char[256];
            int length = GetClassNameW(window, name, name.Length);
            if (length > 0 && new string(name, 0, length) == className) { found = window; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    /// <summary>The largest visible top-level window a process owns; 0 where it has none.</summary>
    public static IntPtr MainWindowOf(uint processId)
    {
        IntPtr best = IntPtr.Zero;
        int bestArea = 0;
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out uint owner);
            if (owner != processId || !IsWindowVisible(window)) return true;
            if (!GetWindowRect(window, out RECT rect)) return true;
            int area = (rect.Right - rect.Left) * (rect.Bottom - rect.Top);
            if (area > bestArea) { bestArea = area; best = window; }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    /// <summary>Raises a window to the foreground, the foreground lock's own way.</summary>
    public static bool Raise(IntPtr window)
    {
        if (window == IntPtr.Zero) return false;
        ShowWindow(window, 9); // SW_RESTORE
        uint target = GetWindowThreadProcessId(window, out _);
        uint current = GetCurrentThreadId();
        bool joined = target != current && AttachThreadInput(current, target, true);
        try
        {
            // The foreground lock lifts on a fresh Alt key event; this is the documented-by-practice unlock.
            keybd_event(0x12, 0, 0, UIntPtr.Zero);
            keybd_event(0x12, 0, 2, UIntPtr.Zero);
            BringWindowToTop(window);
            SwitchToThisWindow(window, true);
            SetForegroundWindow(window);
        }
        finally
        {
            if (joined) AttachThreadInput(current, target, false);
        }
        return GetForegroundWindow() == window;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadIconW(IntPtr instance, IntPtr name);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint ExtractIconExW(string file, int index, out IntPtr large, out IntPtr small, uint count);

    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr icon);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool GetTokenInformation(IntPtr token, int informationClass, out TOKEN_ELEVATION information,
        int length, out int returned);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags,
        [Out] char[] name, ref int size);

    /// <summary>Whether the process runs elevated; false where Windows will not say (the read then decides).</summary>
    public static bool IsElevated(uint processId)
    {
        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process == IntPtr.Zero) return false;
        try
        {
            if (!OpenProcessToken(process, TOKEN_QUERY, out IntPtr token)) return false;
            try
            {
                return GetTokenInformation(token, TokenElevation, out TOKEN_ELEVATION elevation,
                    Marshal.SizeOf<TOKEN_ELEVATION>(), out _) && elevation.TokenIsElevated != 0;
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }

    [DllImport("ntdll.dll")]
    public static extern int NtSuspendProcess(IntPtr process);

    [DllImport("ntdll.dll")]
    public static extern int NtResumeProcess(IntPtr process);

    /// <summary>Suspends or resumes another process of this user; false where it could not be opened.</summary>
    public static bool Suspend(int processId, bool suspend)
    {
        IntPtr process = OpenProcess(0x0800 /* PROCESS_SUSPEND_RESUME */, false, (uint)processId);
        if (process == IntPtr.Zero) return false;
        try { return (suspend ? NtSuspendProcess(process) : NtResumeProcess(process)) == 0; }
        finally { CloseHandle(process); }
    }

    /// <summary>The process's executable file name, for `source`; never its window title.</summary>
    public static string ProcessName(uint processId)
    {
        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process == IntPtr.Zero) return "";
        try
        {
            var buffer = new char[1024];
            int size = buffer.Length;
            return QueryFullProcessImageNameW(process, 0, buffer, ref size)
                ? System.IO.Path.GetFileName(new string(buffer, 0, size)) : "";
        }
        finally { CloseHandle(process); }
    }
}

/// <summary>A message-only window with its own WndProc: the hotkey and the tray talk to it.</summary>
internal sealed class MessageWindow : IDisposable
{
    private readonly Win32.WndProc procedure; // held: the native side points at it
    public IntPtr Handle { get; }

    public MessageWindow(Win32.WndProc procedure)
    {
        this.procedure = procedure;
        Handle = Win32.CreateWindowExW(0, "STATIC", "", 0, 0, 0, 0, 0, Win32.HWND_MESSAGE, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (Handle == IntPtr.Zero) throw new InvalidOperationException("the message-only window was refused");
        Win32.SetWindowLongPtrW(Handle, -4, Marshal.GetFunctionPointerForDelegate(this.procedure));
    }

    public void Dispose() => Win32.DestroyWindow(Handle);
}

// The tray item: a message-only window and Shell_NotifyIconW, with the same lookup the shortcut runs.
using XDict.Models;

namespace XDict.App.Capture;

internal sealed class TrayIcon : IDisposable
{
    public const int CallbackMessage = Win32.WM_APP + 1;
    private const uint IconId = 1;
    private readonly MessageWindow window;
    private readonly Win32.WndProc procedure;
    private IntPtr icon;
    private bool ownedIcon;
    private bool added;

    public event Action? LookupRequested;
    public event Action? OpenRequested;
    public event Action? SettingsRequested;
    public event Action? ExitRequested;

    public TrayIcon()
    {
        procedure = OnMessage;
        window = new MessageWindow(procedure);
    }

    /// <summary>Puts the icon in the notification area; false where the shell refused it.</summary>
    public bool Show()
    {
        icon = LoadTrayIcon(out ownedIcon);
        var data = Data();
        added = Win32.Shell_NotifyIconW(Win32.NIM_ADD, ref data);
        return added;
    }

    public bool Visible => added;

    private Win32.NOTIFYICONDATA Data() => new()
    {
        cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Win32.NOTIFYICONDATA>(),
        hWnd = window.Handle,
        uID = IconId,
        uFlags = Win32.NIF_MESSAGE | Win32.NIF_ICON | Win32.NIF_TIP,
        uCallbackMessage = CallbackMessage,
        hIcon = icon,
        szTip = Strings.Get("app.title"),
        szInfo = "",
        szInfoTitle = "",
    };

    private static IntPtr LoadTrayIcon(out bool owned)
    {
        string executable = Environment.ProcessPath ?? "";
        if (executable.Length > 0 && Win32.ExtractIconExW(executable, 0, out IntPtr large, out IntPtr small, 1) > 0)
        {
            if (large != IntPtr.Zero) Win32.DestroyIcon(large);
            if (small != IntPtr.Zero) { owned = true; return small; }
        }
        owned = false;
        return Win32.LoadIconW(IntPtr.Zero, new IntPtr(32512)); // IDI_APPLICATION
    }

    private IntPtr OnMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == CallbackMessage)
        {
            uint evt = (uint)lParam & 0xFFFF;
            if (evt is Win32.WM_LBUTTONDOWN or Win32.WM_RBUTTONDOWN) ShowMenu();
            return IntPtr.Zero;
        }
        return Win32.DefWindowProcW(hWnd, message, wParam, lParam);
    }

    private void ShowMenu()
    {
        Win32.GetCursorPos(out Win32.POINT point);
        // The tray menu's documented requirement: the window must be foreground or the menu never dismisses.
        Win32.SetForegroundWindow(window.Handle);
        IntPtr menu = Win32.CreatePopupMenu();
        try
        {
            Win32.AppendMenuW(menu, Win32.MF_STRING, 1, Strings.Get("capture.lookup"));
            Win32.AppendMenuW(menu, Win32.MF_STRING, 2, Strings.Get("capture.open"));
            Win32.AppendMenuW(menu, Win32.MF_STRING, 3, Strings.Get("capture.settings"));
            Win32.AppendMenuW(menu, Win32.MF_SEPARATOR, 0, "");
            Win32.AppendMenuW(menu, Win32.MF_STRING, 4, Strings.Get("capture.exit"));
            int command = Win32.TrackPopupMenu(menu, Win32.TPM_RETURNCMD | Win32.TPM_NONOTIFY,
                point.X, point.Y, 0, window.Handle, IntPtr.Zero);
            switch (command)
            {
                case 1: LookupRequested?.Invoke(); break;
                case 2: OpenRequested?.Invoke(); break;
                case 3: SettingsRequested?.Invoke(); break;
                case 4: ExitRequested?.Invoke(); break;
            }
        }
        finally { Win32.DestroyMenu(menu); }
        Win32.SetForegroundWindow(window.Handle);
    }

    public void Dispose()
    {
        if (added)
        {
            var data = Data();
            Win32.Shell_NotifyIconW(Win32.NIM_DELETE, ref data);
            added = false;
        }
        if (ownedIcon && icon != IntPtr.Zero) Win32.DestroyIcon(icon);
        icon = IntPtr.Zero;
        window.Dispose();
    }
}

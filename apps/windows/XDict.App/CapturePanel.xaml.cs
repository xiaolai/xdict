// The panel beside the selection: it must not take the foreground (the reader's selection belongs to the app behind
// it), so it is WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, placed in physical pixels with SetWindowPos, and it dismisses
// itself on Escape or a click outside — both caught by low-level hooks installed only while it is up.
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using XDict.App.Capture;
using XDict.Models;
using WinRT.Interop;

namespace XDict.App;

public sealed partial class CapturePanel : Window
{
    private const int Width = 460;
    private const int Height = 520;
    private const int Gap = 12;

    private readonly Win32.HookProc mouseHook;
    private IntPtr mouse;

    public IntPtr Handle { get; }

    /// <summary>The reader dismissed the panel: Escape, a click outside, or its Close button.</summary>
    public event Action? Dismissed;

    public CapturePanel()
    {
        InitializeComponent();
        ThemeApplier.Apply(Content as FrameworkElement, AppSettings.Load().Theme);
        Title = Strings.Get("app.title");
        Handle = WindowNative.GetWindowHandle(this);
        long style = (long)Win32.GetWindowLongPtrW(Handle, Win32.GWL_EXSTYLE);
        Win32.SetWindowLongPtrW(Handle, Win32.GWL_EXSTYLE,
            new IntPtr(style | Win32.WS_EX_NOACTIVATE | Win32.WS_EX_TOOLWINDOW));
        OpenButton.Content = Strings.Get("capture.openInApp");
        CloseButton.Content = Strings.Get("capture.close");
        OpenButton.Click += (_, _) => OpenRequested?.Invoke(TermText.Text);
        CloseButton.Click += (_, _) => Dismiss();
        mouseHook = (code, wParam, _) => OnMouse(code, wParam);
    }

    public event Action<string>? OpenRequested;

    public void SetContent(string term, string status)
    {
        TermText.Text = term;
        StatusText.Text = status;
    }

    public void SetStatus(string status) => StatusText.Text = status;

    public Grid EntryHostGrid => EntryHost;

    /// <summary>Shows beside the selection's box without activating; the caller checks the foreground did not change.</summary>
    public void ShowAt(SelectionBox? box)
    {
        int x = 0, y = 0;
        if (box is { } measured) (x, y) = Place(measured);
        Win32.SetWindowPos(Handle, Win32.HWND_TOPMOST, x, y, Width, Height, Win32.SWP_NOACTIVATE | Win32.SWP_SHOWWINDOW);
        Shown = true;
        if (mouse == IntPtr.Zero)
            mouse = Win32.SetWindowsHookExW(Win32.WH_MOUSE_LL, mouseHook, Win32.GetModuleHandleW(null), 0);
    }

    public bool Shown { get; private set; }

    public string Term => TermText.Text;

    /// <summary>Below the box when it fits, otherwise above; never off the monitor the selection is on.</summary>
    private static (int X, int Y) Place(SelectionBox box)
    {
        int x = box.X;
        int y = box.Y + box.Height + Gap;
        var rect = new Win32.RECT
        {
            Left = box.X,
            Top = box.Y,
            Right = box.X + Math.Max(box.Width, 1),
            Bottom = box.Y + box.Height,
        };
        var info = new Win32.MONITORINFO { cbSize = (uint)Marshal.SizeOf<Win32.MONITORINFO>() };
        IntPtr monitor = Win32.MonitorFromRect(ref rect, Win32.MONITOR_DEFAULTTONEAREST);
        if (monitor != IntPtr.Zero && Win32.GetMonitorInfoW(monitor, ref info))
        {
            int left = info.rcWork.Left, top = info.rcWork.Top;
            int right = info.rcWork.Right, bottom = info.rcWork.Bottom;
            if (y + Height > bottom) y = Math.Max(top, box.Y - Height - Gap);
            if (x + Width > right) x = Math.Max(left, right - Width);
            if (x < left) x = left;
            return (x, y);
        }
        // No monitor answer: the primary screen is better than no clamp at all.
        int screenWidth = GetSystemMetrics(0), screenHeight = GetSystemMetrics(1);
        if (y + Height > screenHeight) y = Math.Max(0, box.Y - Height - Gap);
        if (x + Width > screenWidth) x = Math.Max(0, screenWidth - Width);
        return (x, y);
    }

    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);

    public void Dismiss()
    {
        if (mouse != IntPtr.Zero)
        {
            Win32.UnhookWindowsHookEx(mouse);
            mouse = IntPtr.Zero;
        }
        Win32.ShowWindow(Handle, 0); // SW_HIDE
        if (!Shown) return;
        Shown = false;
        Dismissed?.Invoke();
    }

    private IntPtr OnMouse(int code, IntPtr wParam)
    {
        if (code >= 0 && wParam == (IntPtr)Win32.WM_LBUTTONDOWN || code >= 0 && wParam == (IntPtr)Win32.WM_RBUTTONDOWN)
        {
            Win32.GetCursorPos(out Win32.POINT point);
            Win32.GetWindowRect(Handle, out Win32.RECT rect);
            bool inside = point.X >= rect.Left && point.X <= rect.Right && point.Y >= rect.Top && point.Y <= rect.Bottom;
            if (!inside) Dismiss();
        }
        return Win32.CallNextHookEx(IntPtr.Zero, code, IntPtr.Zero, IntPtr.Zero);
    }
}

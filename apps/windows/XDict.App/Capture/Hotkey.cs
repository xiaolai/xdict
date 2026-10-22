// The reader's global shortcut (RegisterHotKey): one combination, kept across a relaunch; a clash is reported and the
// old combination keeps working.
using XDict.Models;

namespace XDict.App.Capture;

internal sealed class Hotkey : IDisposable
{
    public const int Id = 0x5844;
    private readonly MessageWindow window;
    private readonly Action pressed;
    private readonly Win32.WndProc procedure; // held: the native side points at it

    public uint Modifiers { get; private set; }
    public uint Key { get; private set; }
    public bool Registered { get; private set; }

    public Hotkey(Action pressed)
    {
        this.pressed = pressed;
        procedure = OnMessage;
        window = new MessageWindow(procedure);
    }

    /// <summary>Registers a combination; false where Windows says it is taken, and nothing is left half-registered.</summary>
    public bool Register(uint modifiers, uint key)
    {
        if (Registered) Win32.UnregisterHotKey(window.Handle, Id);
        Registered = Win32.RegisterHotKey(window.Handle, Id, modifiers | Win32.MOD_NOREPEAT, key);
        if (Registered) { Modifiers = modifiers; Key = key; }
        return Registered;
    }

    public void Unregister()
    {
        if (!Registered) return;
        Win32.UnregisterHotKey(window.Handle, Id);
        Registered = false;
    }

    /// <summary>Rebinds, or reports the clash and puts the previous combination back.</summary>
    public CaptureSettings Rebind(CaptureSettings previous, uint modifiers, uint key)
    {
        try
        {
            return CaptureSettings.TryRebind(modifiers, key, Register, Unregister);
        }
        catch (CaptureClashException)
        {
            Register(previous.Modifiers, previous.Key); // the old combination keeps working
            throw;
        }
    }

    private IntPtr OnMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == Win32.WM_HOTKEY && (int)wParam == Id) pressed();
        return Win32.DefWindowProcW(hWnd, message, wParam, lParam);
    }

    public void Dispose()
    {
        Unregister();
        window.Dispose();
    }
}

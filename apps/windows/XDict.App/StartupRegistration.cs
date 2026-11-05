// Start at login, the reader's own choice: one value under HKCU's Run key, removed when switched off.
using Microsoft.Win32;

namespace XDict.App;

internal static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "XDict";

    public static bool IsEnabled()
    {
        using RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue(Name) is string;
    }

    /// <summary>
    /// Points an enabled Run value at this executable. An upgrade from the x86 install path leaves the value naming
    /// the removed copy; the installer cannot know every reader's HKCU, so each reader repairs their own on launch.
    /// A disabled registration is left absent, not recreated.
    /// </summary>
    public static void Repair()
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key?.GetValue(Name) is not string held) return;
            string expected = "\"" + Environment.ProcessPath + "\"";
            if (!string.Equals(held, expected, StringComparison.OrdinalIgnoreCase)) key.SetValue(Name, expected);
        }
        catch (Exception error) when (error is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            // A denied write leaves the old value; the app still runs, and the reader can toggle it in General.
        }
    }

    /// <summary>Writes or removes the value; false where Windows refused the registry write.</summary>
    public static bool Set(bool enabled)
    {
        try
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey, true);
            if (enabled) key.SetValue(Name, "\"" + Environment.ProcessPath + "\"");
            else key.DeleteValue(Name, false);
            return true;
        }
        catch (Exception error) when (error is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            return false;
        }
    }
}

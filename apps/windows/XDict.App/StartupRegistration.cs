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

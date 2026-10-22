// The reader's capture choices: the hotkey, kept across a relaunch, and the panel's placement preference.
using System.Text.Json;

namespace XDict.Models;

public sealed record CaptureSettings
{
    /// <summary>The default combination: Ctrl+Shift+D. Alt is deliberately absent: in Notepad and other Win32 apps an
    /// Alt chord hands focus to the menu bar and the document's selection is lost before the read.</summary>
    public const uint DefaultModifiers = 0x0002 | 0x0004; // MOD_CONTROL | MOD_SHIFT
    public const uint DefaultKey = 0x44;                   // 'D'

    public uint Modifiers { get; init; } = DefaultModifiers;
    public uint Key { get; init; } = DefaultKey;

    /// <summary>Where the settings file lives; `XDICT_CAPTURE_SETTINGS` overrides it for a lab.</summary>
    public static string Path =>
        Environment.GetEnvironmentVariable("XDICT_CAPTURE_SETTINGS")
        ?? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDict", "capture.json");

    public static CaptureSettings Load(string? path = null)
    {
        path ??= Path;
        try
        {
            if (!File.Exists(path)) return new CaptureSettings();
            return JsonSerializer.Deserialize<CaptureSettings>(File.ReadAllText(path)) ?? new CaptureSettings();
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException)
        {
            return new CaptureSettings();
        }
    }

    public void Save(string? path = null) => SettingsJson.Write(path ?? Path, this);

    /// <summary>"Ctrl+Shift+D": the combination as a reader reads it.</summary>
    public static string Describe(uint modifiers, uint key)
    {
        var parts = new List<string>();
        if ((modifiers & 0x0002) != 0) parts.Add("Ctrl");
        if ((modifiers & 0x0001) != 0) parts.Add("Alt");
        if ((modifiers & 0x0004) != 0) parts.Add("Shift");
        if ((modifiers & 0x0008) != 0) parts.Add("Win");
        parts.Add(KeyName(key));
        return string.Join("+", parts);
    }

    private static string KeyName(uint key) => key switch
    {
        >= 0x41 and <= 0x5A => ((char)key).ToString(),
        >= 0x30 and <= 0x39 => ((char)key).ToString(),
        >= 0x70 and <= 0x87 => "F" + (key - 0x6F),
        _ => "0x" + key.ToString("X2"),
    };

    /// <summary>A rebinding is kept only when Windows gave it; on a clash the caller puts the previous combination
    /// back, as Hotkey.Rebind does.</summary>
    public static CaptureSettings TryRebind(uint modifiers, uint key, Func<uint, uint, bool> register, Action unregisterOld)
    {
        unregisterOld();
        if (register(modifiers, key)) return new CaptureSettings { Modifiers = modifiers, Key = key };
        throw new CaptureClashException(modifiers, key);
    }
}

public sealed class CaptureClashException(uint modifiers, uint key) : Exception(
    $"the combination 0x{modifiers:X} + 0x{key:X} is already taken; the previous one still works")
{
    public uint Modifiers { get; } = modifiers;
    public uint Key { get; } = key;
}

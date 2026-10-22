// The reader's application-wide choices (ADR-0012): the reading face's defaults, the accent and recordings, the
// theme, start-at-login and the capture shortcut. One file, validated on read, written atomically.
using System.Text.Json;

namespace XDict.Models;

public sealed record AppSettings
{
    /// <summary>The reading face's default zoom; a dictionary's own choice still wins.</summary>
    public double Zoom { get; init; } = 1;

    /// <summary>The entry's original stylesheet instead of the reading style.</summary>
    public bool OriginalStyle { get; init; }

    /// <summary>The dictionary's own recording plays when the system can decode it.</summary>
    public bool UseRecordings { get; init; }

    /// <summary>"uk" or "us": which English voice the reader prefers.</summary>
    public string Accent { get; init; } = "us";

    /// <summary>"light", "dark", or "system".</summary>
    public string Theme { get; init; } = "system";

    public bool StartAtLogin { get; init; }

    public static string Path =>
        Environment.GetEnvironmentVariable("XDICT_SETTINGS")
        ?? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDict", "settings.json");

    /// <summary>Illegal values are clamped to the nearest legal one, never silently kept.</summary>
    public AppSettings Validated() => this with
    {
        Zoom = double.IsFinite(Zoom) ? Math.Clamp(Zoom, 0.5, 3) : 1,
        Accent = Accent is "uk" or "us" ? Accent : "us",
        Theme = Theme is "light" or "dark" or "system" ? Theme : "system",
    };

    public static AppSettings Load(string? path = null)
    {
        path ??= Path;
        try
        {
            if (!File.Exists(path)) return new AppSettings();
            return (JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new AppSettings()).Validated();
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException)
        {
            return new AppSettings();
        }
    }

    public void Save(string? path = null) => SettingsJson.Write(path ?? Path, Validated());
}

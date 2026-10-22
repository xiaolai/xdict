using System.Text.Json;

namespace XDict.Models;

public sealed record ReadingPreferences(double Zoom = 1, string Theme = "light", bool OriginalStyle = false, IReadOnlyDictionary<string, string>? DisplayOptions = null)
{
    public ReadingPreferences Validated() => this with
    {
        Zoom = double.IsFinite(Zoom) ? Math.Clamp(Zoom, 0.5, 3) : 1,
        Theme = Theme is "light" or "dark" ? Theme : "light",
    };
}

// Durable edition identity owns the choices, never a path or a temporary service handle.
public sealed class ReadingPreferenceStore(string path)
{
    /// <summary>Where the per-edition reading choices live when the app does not say otherwise.</summary>
    public static string DefaultPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDict", "reading.json");

    /// <summary>
    /// A dictionary with no choice of its own starts from the application's (Settings ▸ Reading & Speech). "system"
    /// is resolved to the theme in force when the choice is made, not forced to light: with Windows in dark mode
    /// every entry would otherwise render light forever.
    /// </summary>
    public static ReadingPreferences FromSettings(AppSettings settings, string systemTheme) =>
        new(settings.Zoom,
            settings.Theme is "light" or "dark" ? settings.Theme : (systemTheme == "dark" ? "dark" : "light"),
            settings.OriginalStyle);

    public bool Has(string edition) => Load().ContainsKey(edition);

    private Dictionary<string, ReadingPreferences> Load()
    {
        try { return JsonSerializer.Deserialize<Dictionary<string, ReadingPreferences>>(File.ReadAllText(path)) ?? []; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return []; }
    }
    public ReadingPreferences Read(string edition) => (Load().GetValueOrDefault(edition) ?? new()).Validated();
    public void Write(string edition, ReadingPreferences value)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(edition);
        var values = Load();
        values[edition] = value.Validated();
        SettingsJson.Write(path, values);
    }
}

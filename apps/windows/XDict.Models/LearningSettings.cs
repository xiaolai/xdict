// What the learning surfaces keep: the history switch and the target languages it filters on. The history is off
// until the first-run disclosure has been read (ADR-0023: on for a new reader, after the setup says it is kept
// locally); the Learning pane owns the switch after that.
using System.Text.Json;

namespace XDict.Models;

public sealed record LearningSettings
{
    /// <summary>Off until the first-run disclosure acknowledges it. With it off the recorder writes nothing at all.</summary>
    public bool HistoryEnabled { get; init; }

    /// <summary>The reader's target languages; empty keeps every language (plan §2.7).</summary>
    public List<string>? TargetLanguages { get; init; } = [];

    /// <summary>The set the recorder sends, never null even from an older file.</summary>
    public IReadOnlyList<string> Targets => TargetLanguages ?? [];

    /// <summary>The review's target recall; the scheduler's own default until the reader changes it.</summary>
    public double ReviewRetention { get; init; } = 0.9;

    /// <summary>The scheduler's interval cap.</summary>
    public int MaximumDays { get; init; } = 36500;

    /// <summary>Whether review reminders are scheduled; the toast itself is the shell's.</summary>
    public bool RemindersEnabled { get; init; } = true;

    /// <summary>The validated policy a grade carries, whatever the file said.</summary>
    public ReviewPolicy Policy => new(
        double.IsFinite(ReviewRetention) && ReviewRetention > 0 && ReviewRetention < 1 ? ReviewRetention : 0.9,
        MaximumDays >= 1 ? MaximumDays : 36500);

    public static string Path =>
        Environment.GetEnvironmentVariable("XDICT_LEARNING")
        ?? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "XDict", "learning.json");

    public static LearningSettings Load(string? path = null)
    {
        path ??= Path;
        try
        {
            if (!File.Exists(path)) return new LearningSettings();
            LearningSettings loaded = JsonSerializer.Deserialize<LearningSettings>(File.ReadAllText(path)) ?? new();
            return loaded with { TargetLanguages = loaded.TargetLanguages ?? [] };
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException)
        {
            return new LearningSettings();
        }
    }

    public void Save(string? path = null) => SettingsJson.Write(path ?? Path, this);
}

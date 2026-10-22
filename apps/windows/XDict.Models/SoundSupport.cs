// A dictionary recording, told apart before anything plays: present and playable, present in a format the platform
// does not play (Speex), or missing from the package. The shell words each; playback is the sound work (WI-8).
namespace XDict.Models;

public enum SoundKind
{
    Playable,
    Unsupported,
    Missing,
}

public sealed record SoundChoice(SoundKind Kind, string Path, string? Mime);

public static class SoundSupport
{
    public static SoundChoice Classify(string path, bool found, string? mime)
    {
        if (!found) return new SoundChoice(SoundKind.Missing, path, mime);
        string extension = Path.GetExtension(path).ToLowerInvariant();
        bool speex = extension is ".spx" or ".speex" ||
            (mime?.Contains("speex", StringComparison.OrdinalIgnoreCase) ?? false);
        if (speex) return new SoundChoice(SoundKind.Unsupported, path, mime);
        return extension is ".mp3" or ".wav" or ".ogg" or ".oga" or ".m4a" or ".aac" or ".flac"
            ? new SoundChoice(SoundKind.Playable, path, mime)
            : new SoundChoice(SoundKind.Unsupported, path, mime);
    }

    /// <summary>The sentence for each outcome: the missing and the unsupported are never the same notice.</summary>
    public static string Sentence(SoundKind kind, string? language = null) => kind switch
    {
        SoundKind.Missing => Strings.Get("sound.missing", language ?? Strings.Language),
        SoundKind.Unsupported => Strings.Get("sound.unsupported", language ?? Strings.Language),
        _ => "",
    };
}

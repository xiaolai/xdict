// The system voice both speech paths use: one enumeration for the catalogue, one place that applies SpeechText's
// choice to a synthesizer. The main window and the sound lab had the same three steps copied.
using Windows.Media.SpeechSynthesis;
using XDict.Models;

namespace XDict.App;

internal static class VoicePicker
{
    public static (string Name, string Language)[] Voices() =>
        SpeechSynthesizer.AllVoices.Select(voice => (voice.DisplayName, voice.Language)).ToArray();

    /// <summary>Sets the synthesizer's voice for a language and the reader's accent; null when nothing matched.</summary>
    public static SpeechSynthesizer? Choose(this SpeechSynthesizer synthesizer,
        (string Name, string Language)[] voices, string language, string? accent = null)
    {
        string? chosen = SpeechText.ChooseVoice(voices, language, accent);
        if (chosen is null) return null;
        synthesizer.Voice = SpeechSynthesizer.AllVoices.First(voice => voice.DisplayName == chosen);
        return synthesizer;
    }
}

// What the shell says and with which voice: the SSML for a word (IPA when the dictionary gives it) and the choice of
// a system voice for the dictionary's language and the reader's accent. The synthesis itself is the shell's (WinRT).
using System.Security;

namespace XDict.Models;

public static class SpeechText
{
    /// <summary>
    /// The SSML for one word. With an IPA transcription the phoneme is the pronunciation and the text is its fallback;
    /// without one the word is spoken as written. Everything is XML-escaped.
    /// </summary>
    public static string Ssml(string text, string? ipa, string language)
    {
        string escaped = SecurityElement.Escape(text) ?? "";
        string lang = SecurityElement.Escape(language) ?? "en";
        if (string.IsNullOrWhiteSpace(ipa))
            return $"<speak version=\"1.0\" xml:lang=\"{lang}\"><prosody>{escaped}</prosody></speak>";
        string phoneme = SecurityElement.Escape(ipa) ?? "";
        return $"<speak version=\"1.0\" xml:lang=\"{lang}\"><phoneme alphabet=\"ipa\" ph=\"{phoneme}\">{escaped}</phoneme></speak>";
    }

    /// <summary>
    /// The voice to speak a dictionary's language with, preferring the reader's accent: en-GB for a British accent,
    /// en-US for an American one, any en voice otherwise; zh-CN for Chinese; the language's first voice as a fallback.
    /// </summary>
    public static string? ChooseVoice(IEnumerable<(string Name, string Language)> voices, string language, string? accent = null)
    {
        var list = voices.ToList();
        string Lang(string value) => value.Split('-')[0].ToLowerInvariant();
        string wanted = language.Split('-')[0].ToLowerInvariant();
        // An accent names a variety of English; asking a Chinese voice for "uk" must not return an English one.
        string? exact = wanted == "en" ? accent switch
        {
            "uk" or "en-GB" => "en-gb",
            "us" or "en-US" => "en-us",
            _ => null,
        } : null;
        if (exact is not null)
        {
            var accented = list.FirstOrDefault(voice => voice.Language.ToLowerInvariant() == exact);
            if (accented.Name is not null) return accented.Name;
        }
        var sameLanguage = list.FirstOrDefault(voice => Lang(voice.Language) == wanted);
        if (sameLanguage.Name is not null) return sameLanguage.Name;
        if (wanted == "zh")
        {
            var chinese = list.FirstOrDefault(voice => voice.Language.ToLowerInvariant().StartsWith("zh-cn"));
            if (chinese.Name is not null) return chinese.Name;
        }
        return null;
    }
}

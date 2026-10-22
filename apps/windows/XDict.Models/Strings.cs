// The reader-facing strings. One catalogue, two languages; a key missing from either is a startup failure here and a
// test failure in XDict.Tests. WI-10 generates the full catalogue from the macOS one; these are the skeleton's.
using System.Globalization;
using System.Text.Json;

namespace XDict.Models;

public static class Strings
{
    public const string English = "en";
    public const string SimplifiedChinese = "zh-Hans";

    private static readonly IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Catalogue = Load();

    /// <summary>The language this session reads: Chinese for any zh culture, English otherwise.</summary>
    public static string Language =>
        CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? SimplifiedChinese : English;

    public static IReadOnlyCollection<string> Languages => (IReadOnlyCollection<string>)Catalogue.Keys;

    public static IReadOnlyCollection<string> Keys => Catalogue.Values.First().Keys.ToArray();

    public static string Get(string key) => Get(key, Language);

    public static string Get(string key, string language)
    {
        if (!Catalogue.TryGetValue(language, out IReadOnlyDictionary<string, string>? table))
            throw new InvalidOperationException($"the catalogue has no language {language}");
        if (!table.TryGetValue(key, out string? value) || string.IsNullOrEmpty(value))
            throw new InvalidOperationException($"the catalogue has no string {key} in {language}");
        return value;
    }

    public static string Format(string key, params object?[] arguments) =>
        string.Format(CultureInfo.CurrentCulture, Get(key), arguments);

    private static IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Load()
    {
        using Stream stream = typeof(Strings).Assembly.GetManifestResourceStream("XDict.Models.strings.json")
            ?? throw new InvalidOperationException("the string catalogue is not embedded");
        using JsonDocument document = JsonDocument.Parse(stream);
        var catalogue = new Dictionary<string, IReadOnlyDictionary<string, string>>(StringComparer.Ordinal);
        foreach (JsonProperty language in document.RootElement.EnumerateObject())
        {
            var table = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (JsonProperty entry in language.Value.EnumerateObject())
                table[entry.Name] = entry.Value.GetString()
                    ?? throw new InvalidOperationException($"{language.Name}/{entry.Name} is not a string");
            catalogue[language.Name] = table;
        }
        if (catalogue.Count is 0) throw new InvalidOperationException("the string catalogue is empty");
        string[] keys = catalogue.Values.First().Keys.Order(StringComparer.Ordinal).ToArray();
        foreach ((string language, IReadOnlyDictionary<string, string> table) in catalogue)
        {
            string[] other = table.Keys.Order(StringComparer.Ordinal).ToArray();
            if (!keys.SequenceEqual(other, StringComparer.Ordinal))
                throw new InvalidOperationException($"the catalogue's {language} keys differ from {English}");
        }
        return catalogue;
    }
}

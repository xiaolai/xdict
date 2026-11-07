// The UI's string gate: every key the app asks for exists in both languages, no route is unnamed for UIA, and no
// reader-facing sentence is written as a literal in XAML.
using System.Text.RegularExpressions;
using XDict.Models;
using Xunit;

public class SettingsStringsTests
{
    private static string AppRoot()
    {
        DirectoryInfo? directory = new(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "XDict.App")))
            directory = directory.Parent;
        Assert.NotNull(directory);
        return Path.Combine(directory!.FullName, "XDict.App");
    }

    [Fact]
    public void EveryKeyTheAppAsksForExistsInBothLanguages()
    {
        var used = new SortedSet<string>(StringComparer.Ordinal);
        foreach (string file in Directory.GetFiles(AppRoot(), "*.cs", SearchOption.AllDirectories))
        {
            string text = File.ReadAllText(file);
            foreach (Match match in Regex.Matches(text, "Strings\\.(?:Get|Format)\\(\"([^\"]+)\""))
                used.Add(match.Groups[1].Value);
        }
        Assert.NotEmpty(used);
        foreach (string key in used)
        {
            foreach (string language in Strings.Languages)
                Assert.False(string.IsNullOrWhiteSpace(Strings.Get(key, language)), $"{language} has no {key}");
        }
    }

    [Fact]
    public void EveryKeyShapedLiteralIsAKeyOrAKeyPrefix()
    {
        // The call-site regex sees `Strings.Get("key")` and nothing else: a switch's arms, a ternary and
        // `"meaning.outcome." + outcome` are looked up dynamically. Every literal shaped like a catalogue key must be
        // one — or a prefix of one, for the concatenated form — so a missing arm or a typo is a failing test.
        var groups = Strings.Keys.Select(key => key.Split('.')[0]).ToHashSet(StringComparer.Ordinal);
        var offenders = new List<string>();
        foreach (string file in Directory.GetFiles(AppRoot(), "*.cs", SearchOption.AllDirectories))
        {
            string text = File.ReadAllText(file);
            foreach (Match match in Regex.Matches(text, "\"([A-Za-z][A-Za-z0-9]*(?:\\.[A-Za-z0-9]+)*\\.?)\""))
            {
                string literal = match.Groups[1].Value;
                if (!literal.Contains('.')) continue;
                // A resource's own name in a URL or a file join (`find.js`), not a look-up key.
                if (Regex.IsMatch(literal, @"\.(js|css|json|html?|txt|mdx|mdd|exe|dll|xbf|pri|xaml)$")) continue;
                string group = literal.Split('.')[0];
                if (!groups.Contains(group)) continue;
                if (Strings.Keys.Contains(literal)) continue;
                if (literal.EndsWith('.') && Strings.Keys.Any(key =>
                        key.StartsWith(literal, StringComparison.Ordinal))) continue;
                offenders.Add(Path.GetFileName(file) + ": " + literal);
            }
        }
        Assert.True(offenders.Count == 0,
            "key-shaped literals that are not catalogue keys: " + string.Join(" | ", offenders));
    }

    [Fact]
    public void EverySettingsRouteIsNamedForAutomation()
    {
        string xaml = File.ReadAllText(Path.Combine(AppRoot(), "SettingsWindow.xaml"));
        foreach (string id in new[]
                 {
                     "SettingsNav", "SettingsDictionaries", "SettingsReading", "SettingsSpeech", "SettingsLookup",
                     "SettingsLearning", "SettingsAI", "SettingsGeneral", "SettingsSetup", "SettingsAbout",
                 })
            Assert.Contains("AutomationProperties.AutomationId=\"" + id + "\"", xaml);
    }

    [Fact]
    public void NoReaderFacingLiteralIsWrittenInXaml()
    {
        var offenders = new List<string>();
        foreach (string file in Directory.GetFiles(AppRoot(), "*.xaml"))
        {
            string text = File.ReadAllText(file);
            foreach (Match match in Regex.Matches(text,
                         "\\b(?:Text|Content|Header|PlaceholderText)\\s*=\\s*\"([^\"]*)\""))
            {
                string value = match.Groups[1].Value.Trim();
                if (value.Length > 0 && !value.StartsWith('{')) offenders.Add(Path.GetFileName(file) + ": " + value);
            }
        }
        Assert.True(offenders.Count == 0, "reader-facing literals: " + string.Join(" | ", offenders));
    }
}

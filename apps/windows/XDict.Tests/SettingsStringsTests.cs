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
    public void EverySettingsRouteIsNamedForAutomation()
    {
        string xaml = File.ReadAllText(Path.Combine(AppRoot(), "SettingsWindow.xaml"));
        foreach (string id in new[] { "SettingsNav", "SettingsDictionaries", "SettingsReading", "SettingsGeneral" })
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

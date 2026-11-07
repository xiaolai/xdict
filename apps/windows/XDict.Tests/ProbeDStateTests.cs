// Probe D's reader-state acceptance (plan §0a, D11): run with XDICT_PROBE_STATE naming a populated
// %LOCALAPPDATA%\XDict. It is inert in every other run. The state is written by 0.1.6 and read by the 0.2.0 build;
// the MSI's upgrade itself is the installer evidence, this is the model's half.
using System.Runtime.Versioning;
using System.Text.Json;
using Microsoft.Win32;
using XDict.Models;
using Xunit;

/// <summary>A fact that reports a skip when the acceptance configuration is absent, instead of passing with no
/// assertion run.</summary>
public sealed class ProbeDStateFactAttribute : FactAttribute
{
    public ProbeDStateFactAttribute()
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("XDICT_PROBE_STATE")))
            Skip = "XDICT_PROBE_STATE is not set: the upgrade acceptance run names the populated state";
    }
}

[SupportedOSPlatform("windows")]
public class ProbeDStateTests
{
    /// <summary>The state this run reads, or a skip that says so. A variable that is set to a wrong path is not
    /// skipped: the test runs and its assertions fail, which is the difference between "not asked" and "passed".</summary>
    private static string Root =>
        Environment.GetEnvironmentVariable("XDICT_PROBE_STATE") is { Length: > 0 } root
            ? root
            : throw new InvalidOperationException("XDICT_PROBE_STATE names the populated state");

    [ProbeDStateFact]
    public void TheReadersStateSurvivesTheUpgrade()
    {
        string root = Root;

        AppSettings settings = AppSettings.Load(Path.Combine(root, "settings.json"));
        Assert.Equal(1.25, settings.Zoom);
        Assert.True(settings.OriginalStyle);
        Assert.True(settings.UseRecordings);
        Assert.Equal("uk", settings.Accent);
        Assert.Equal("dark", settings.Theme);
        Assert.True(settings.StartAtLogin);
        using (JsonDocument raw = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "settings.json"))))
            Assert.True(raw.RootElement.TryGetProperty("LegacyMovedKey", out _),
                "the upgrade must not rewrite the reader's settings file");

        LibraryStore library = LibraryStore.Load(Path.Combine(root, "library.json"));
        Assert.Equal(2, library.Dictionaries.Count);
        Assert.Equal("Tiny", library.Dictionaries[0].DisplayName);
        Assert.Equal(0, library.Dictionaries[0].Order);
        Assert.True(library.Dictionaries[0].Enabled);
        Assert.Equal("Dropped renamed", library.Dictionaries[1].DisplayName);
        Assert.Equal(1, library.Dictionaries[1].Order);
        Assert.True(library.Dictionaries[1].Enabled);
        Assert.All(library.Dictionaries, item => Assert.False(string.IsNullOrWhiteSpace(item.Edition)));
        // Each dictionary's files, not just the union: an upgrade that dropped every reference of one dictionary left
        // Assert.All over an empty list vacuously green.
        foreach (LibraryDictionary dictionary in library.Dictionaries)
        {
            Assert.NotEmpty(dictionary.Files);
            LibraryFile mdx = Assert.Single(dictionary.Files, file => file.Role == LibraryRole.Mdx);
            Assert.Equal(0, mdx.Order);
            Assert.False(string.IsNullOrWhiteSpace(mdx.Name));
            Assert.All(dictionary.Files, file => Assert.True(File.Exists(file.Path), file.Path));
        }

        CaptureSettings capture = CaptureSettings.Load(Path.Combine(root, "capture.json"));
        Assert.Equal(3u, capture.Modifiers);
        Assert.Equal(81u, capture.Key);

        ReadingPreferenceStore reading = new(Path.Combine(root, "reading.json"));
        Assert.Equal(1.25, reading.Read(library.Dictionaries[0].Edition).Zoom);
        Assert.Equal("dark", reading.Read(library.Dictionaries[0].Edition).Theme);
        Assert.Equal(1.5, reading.Read(library.Dictionaries[1].Edition).Zoom);

        using (RegistryKey? run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
        {
            // The expected target is derived from this machine's installed artifact, not from the obsolete x86 path:
            // StartupRegistration.Repair updates that command, and the check must follow what it registers.
            string? command = run?.GetValue("XDict") as string;
            Assert.False(string.IsNullOrWhiteSpace(command), "the Run key has no XDict command");
            string target = command!.Trim('"');
            string expected = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "XDict", "XDict.exe");
            Assert.Equal(expected, target, StringComparer.OrdinalIgnoreCase);
            Assert.True(File.Exists(target), $"the Run command's target does not exist: {target}");
        }
        Assert.True(Directory.Exists(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Packages", "ai.xdict.app.dictionaryservice", "AC")));
    }
}

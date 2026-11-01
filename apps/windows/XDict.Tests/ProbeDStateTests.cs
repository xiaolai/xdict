// Probe D's reader-state acceptance (plan §0a, D11): run with XDICT_PROBE_STATE naming a populated
// %LOCALAPPDATA%\XDict. It is inert in every other run. The state is written by 0.1.6 and read by the 0.2.0 build;
// the MSI's upgrade itself is the installer evidence, this is the model's half.
using System.Runtime.Versioning;
using System.Text.Json;
using Microsoft.Win32;
using XDict.Models;
using Xunit;

[SupportedOSPlatform("windows")]
public class ProbeDStateTests
{
    [Fact]
    public void TheReadersStateSurvivesTheUpgrade()
    {
        string? root = Environment.GetEnvironmentVariable("XDICT_PROBE_STATE");
        if (string.IsNullOrWhiteSpace(root)) return;

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
        Assert.All(library.Dictionaries.SelectMany(item => item.Files), file => Assert.True(File.Exists(file.Path), file.Path));

        CaptureSettings capture = CaptureSettings.Load(Path.Combine(root, "capture.json"));
        Assert.Equal(3u, capture.Modifiers);
        Assert.Equal(81u, capture.Key);

        ReadingPreferenceStore reading = new(Path.Combine(root, "reading.json"));
        Assert.Equal(1.25, reading.Read(library.Dictionaries[0].Edition).Zoom);
        Assert.Equal("dark", reading.Read(library.Dictionaries[0].Edition).Theme);
        Assert.Equal(1.5, reading.Read(library.Dictionaries[1].Edition).Zoom);

        using (RegistryKey? run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
            Assert.Equal("\"C:\\Program Files (x86)\\XDict\\XDict.exe\"", run?.GetValue("XDict") as string);
        Assert.True(Directory.Exists(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Packages", "ai.xdict.app.dictionaryservice", "AC")));
    }
}

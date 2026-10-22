using XDict.Models;
using Xunit;

public class AppSettingsTests
{
    private static string TempFile() => Path.Combine(Path.GetTempPath(), "xdict-settings-" + Guid.NewGuid().ToString("N") + ".json");

    [Fact]
    public void TheDefaultsRoundTrip()
    {
        string path = TempFile();
        try
        {
            new AppSettings().Save(path);
            AppSettings loaded = AppSettings.Load(path);
            Assert.Equal(1, loaded.Zoom);
            Assert.Equal("us", loaded.Accent);
            Assert.Equal("system", loaded.Theme);
            Assert.False(loaded.UseRecordings);
            Assert.False(loaded.StartAtLogin);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void EveryChoiceIsKept()
    {
        string path = TempFile();
        try
        {
            var chosen = new AppSettings { Zoom = 1.75, OriginalStyle = true, UseRecordings = true, Accent = "uk", Theme = "dark", StartAtLogin = true };
            chosen.Save(path);
            Assert.Equal(chosen, AppSettings.Load(path));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void IllegalValuesAreClampedAndAMalformedFileFallsBack()
    {
        AppSettings clamped = (new AppSettings { Zoom = 9, Accent = "fr", Theme = "neon" }).Validated();
        Assert.Equal(3, clamped.Zoom);
        Assert.Equal("us", clamped.Accent);
        Assert.Equal("system", clamped.Theme);
        Assert.Equal(0.5, (new AppSettings { Zoom = 0 }).Validated().Zoom);

        string path = TempFile();
        try
        {
            File.WriteAllText(path, "{not json");
            Assert.Equal(new AppSettings(), AppSettings.Load(path));
        }
        finally { File.Delete(path); }
    }
}

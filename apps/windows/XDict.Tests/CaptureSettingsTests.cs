using XDict.Models;
using Xunit;

public class CaptureSettingsTests
{
    [Fact]
    public void TheDefaultIsKeptAndARelaunchReadsItBack()
    {
        string folder = Path.Combine(Path.GetTempPath(), "xdict-capture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            string path = Path.Combine(folder, "capture.json");
            CaptureSettings.Load(path).Save(path);
            CaptureSettings loaded = CaptureSettings.Load(path);
            Assert.Equal(CaptureSettings.DefaultModifiers, loaded.Modifiers);
            Assert.Equal(CaptureSettings.DefaultKey, loaded.Key);

            var rebound = new CaptureSettings { Modifiers = 0x0002 | 0x0001 | 0x0004, Key = 0x4B }; // Ctrl+Alt+Shift+K
            rebound.Save(path);
            CaptureSettings afterRelaunch = CaptureSettings.Load(path);
            Assert.Equal(rebound.Modifiers, afterRelaunch.Modifiers);
            Assert.Equal(rebound.Key, afterRelaunch.Key);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public void AClashKeepsTheOldCombinationAndSaysSo()
    {
        bool oldUnregistered = false;
        Assert.Throws<CaptureClashException>(() => CaptureSettings.TryRebind(0x0002, 0x51,
            (_, _) => false, () => oldUnregistered = true));
        Assert.True(oldUnregistered);
        CaptureSettings taken = CaptureSettings.TryRebind(0x0002, 0x51, (_, _) => true, () => { });
        Assert.Equal(0x51u, taken.Key);
    }

    [Fact]
    public void ACombinationReadsAsAReaderWouldSayIt()
    {
        Assert.Equal("Ctrl+Shift+D", CaptureSettings.Describe(0x0006, 0x44));
        Assert.Equal("Ctrl+Alt+Win+F9", CaptureSettings.Describe(0x000B, 0x78));
        Assert.Equal("Shift+0x1B", CaptureSettings.Describe(0x0004, 0x1B));
    }

    [Fact]
    public void AMalformedFileFallsBackToTheDefault()
    {
        string folder = Path.Combine(Path.GetTempPath(), "xdict-capture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            string path = Path.Combine(folder, "capture.json");
            File.WriteAllText(path, "{not json");
            Assert.Equal(CaptureSettings.DefaultKey, CaptureSettings.Load(path).Key);
        }
        finally { Directory.Delete(folder, true); }
    }
}

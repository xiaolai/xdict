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
        var previous = new CaptureSettings();
        var registered = new List<(uint Modifiers, uint Key)>();
        bool oldUnregistered = false;
        // The whole sequence, not only the exception: the old combination is unregistered, the new one is refused,
        // and the old one is registered again, so the reader's shortcut keeps working through a clash.
        Assert.Throws<CaptureClashException>(() => CaptureSettings.TryRebind(previous, 0x0002, 0x51,
            (modifiers, key) => { registered.Add((modifiers, key)); return false; },
            () => oldUnregistered = true));
        Assert.True(oldUnregistered);
        Assert.Equal(new[] { (0x0002u, 0x51u), (previous.Modifiers, previous.Key) }, registered);
        // Success keeps the new combination and nothing is restored.
        registered.Clear();
        CaptureSettings taken = CaptureSettings.TryRebind(previous, 0x0002, 0x51,
            (modifiers, key) => { registered.Add((modifiers, key)); return true; }, () => { });
        Assert.Equal(new[] { (0x0002u, 0x51u) }, registered);
        Assert.Equal(0x51u, taken.Key);
        Assert.Same(previous.Hover, taken.Hover);
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

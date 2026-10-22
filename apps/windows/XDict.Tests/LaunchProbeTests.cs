// The launch probe, without a window: the record the harness reads, and the quit file it writes.
using System.Text.Json;
using XDict.Contract;
using XDict.Models;
using Xunit;

public class LaunchProbeTests
{
    [Fact]
    public void TheRecordNamesTheVersionsInCamelCase()
    {
        LaunchProbe probe = NewProbe(out string directory);
        try
        {
            probe.RecordVersions(new Versions(1, "0.0.6", 2, 1), servicePid: 1234);
            using JsonDocument record = JsonDocument.Parse(File.ReadAllText(probe.RecordPath));
            JsonElement root = record.RootElement;
            Assert.Equal(probe.Id, root.GetProperty("id").GetString());
            Assert.True(root.GetProperty("pid").GetInt32() > 0);
            JsonElement versions = root.GetProperty("versions");
            Assert.Equal(1u, versions.GetProperty("protocol").GetUInt32());
            Assert.Equal("0.0.6", versions.GetProperty("core").GetString());
            Assert.Equal(2u, versions.GetProperty("indexFormat").GetUInt32());
            Assert.Equal(1u, versions.GetProperty("normalization").GetUInt32());
            Assert.Equal(1234, root.GetProperty("servicePid").GetInt32());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task TheQuitFileEndsTheWait()
    {
        LaunchProbe probe = NewProbe(out string directory);
        try
        {
            Task wait = probe.WaitForQuitAsync();
            await Task.Delay(TimeSpan.FromMilliseconds(600));
            Assert.False(wait.IsCompleted, "the wait ended before the quit file existed");
            await File.WriteAllTextAsync(probe.QuitPath, string.Empty);
            await wait.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void TheLaunchIdIsTheArgumentAfterTheFlag()
    {
        Assert.Equal("abc", LaunchProbe.IdFromArgs(["XDict.exe", "--launch-id", "abc"]));
        Assert.Null(LaunchProbe.IdFromArgs(["XDict.exe"]));
        Assert.Null(LaunchProbe.IdFromArgs(["XDict.exe", "--launch-id"]));
        Assert.Null(LaunchProbe.IdFromArgs(["XDict.exe", "--launch-id", " "]));
    }

    private static LaunchProbe NewProbe(out string directory)
    {
        directory = Path.Combine(Path.GetTempPath(), "xdict-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        return new LaunchProbe(directory, "probe-" + Guid.NewGuid().ToString("N"));
    }
}

// The details pane's data: the health check and the reading-style report are read through the service while the
// dictionary is open, and survive a reload of the library file.
using System.Text.Json;
using XDict.Client;
using XDict.Models;
using Xunit;

public class LibraryInspectorTests
{
    [Fact]
    public async Task HealthAndStyleAreReadAndStored()
    {
        string fixtures = Environment.GetEnvironmentVariable("XDICT_FIXTURES")
            ?? throw new InvalidOperationException("XDICT_FIXTURES must name the generated conformance fixtures");
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE must name the built service");
        using var client = new ServiceClient(service);
        client.Handshake();
        LibraryDictionary record = await LibraryImporter.ImportAsync(client,
            PackageFinder.Discover(Path.Combine(fixtures, "tiny", "tiny.mdx")));
        LibraryDictionary inspected = await LibraryInspector.InspectAsync(client, record);
        Assert.NotNull(inspected.HealthJson);
        Assert.NotNull(inspected.StyleJson);
        using (JsonDocument health = JsonDocument.Parse(inspected.HealthJson!))
            Assert.True(health.RootElement.GetProperty("entries").GetUInt64() > 0);
        using (JsonDocument style = JsonDocument.Parse(inspected.StyleJson!))
            Assert.True(style.RootElement.TryGetProperty("version", out _));

        string path = Path.Combine(Path.GetTempPath(), "xdict-inspector-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            LibraryStore store = LibraryStore.Load(path);
            store.Add(inspected);
            store.SetReports(inspected.Edition, inspected.HealthJson, inspected.StyleJson);
            LibraryStore reloaded = LibraryStore.Load(path);
            LibraryDictionary stored = reloaded.Dictionaries.Single(item => item.Edition == inspected.Edition);
            Assert.Equal(inspected.HealthJson, stored.HealthJson);
            Assert.Equal(inspected.StyleJson, stored.StyleJson);
        }
        finally
        {
            File.Delete(path);
        }
    }
}

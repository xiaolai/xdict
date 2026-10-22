// Importing the tiny fixture through the production service into a library record: the core's edition and lineage,
// the header's title, the file list, and the language pair proposed from the name.
using XDict.Client;
using XDict.Models;
using Xunit;

public class LibraryImportTests
{
    [Fact]
    public async Task TheTinyFixtureBecomesALibraryRecord()
    {
        string fixtures = Environment.GetEnvironmentVariable("XDICT_FIXTURES")
            ?? throw new InvalidOperationException("XDICT_FIXTURES must name the generated conformance fixtures");
        string directory = Path.Combine(fixtures, "tiny");
        PackageFiles package = PackageFinder.Discover(Path.Combine(directory, "tiny.mdx"));
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE must name the built service");
        using var client = new ServiceClient(service);
        client.Handshake();
        LibraryDictionary record = await LibraryImporter.ImportAsync(client, package);
        Assert.StartsWith("mdx-sha256-v1:", record.Edition);
        Assert.False(string.IsNullOrWhiteSpace(record.Lineage));
        Assert.Equal("Tiny", record.Title);
        Assert.Equal(3, record.Files.Count);
        Assert.Contains(record.Files, file => file.Role == LibraryRole.Mdd);
        Assert.Contains(record.Files, file => file.Role == LibraryRole.Sidecar && file.Name == "tiny.css");
        Assert.Equal(("en", "en"), (record.SearchLanguage, record.ExplainLanguage));
    }
}

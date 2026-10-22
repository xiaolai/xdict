// Every dictionary of the 24-corpus registers the edition index_bench computed for it: the library's import answer
// must equal the core's own baseline, folder by folder.
using System.Text.Json;
using XDict.Client;
using XDict.Models;
using Xunit;

public class LibraryCorpusTests
{
    [Fact]
    public async Task EveryCorpusDictionaryRegistersTheBenchmarkedEdition()
    {
        string corpus = Environment.GetEnvironmentVariable("XDICT_CORPUS")
            ?? throw new InvalidOperationException("XDICT_CORPUS must name the corpus");
        string editionsPath = Environment.GetEnvironmentVariable("XDICT_EDITIONS")
            ?? throw new InvalidOperationException("XDICT_EDITIONS must name index_bench's edition map");
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE must name the built service");
        Dictionary<string, string> expected = JsonSerializer.Deserialize<Dictionary<string, string>>(
            File.ReadAllText(editionsPath))!;
        using var client = new ServiceClient(service);
        client.Handshake();
        int compared = 0;
        foreach (string folder in Directory.GetDirectories(corpus).OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
        {
            string name = Path.GetFileName(folder);
            if (name.StartsWith('_')) continue;
            string mdx = Directory.GetFiles(folder, "*.mdx", SearchOption.TopDirectoryOnly).Single();
            LibraryDictionary record = await LibraryImporter.ImportAsync(client, PackageFinder.Discover(mdx));
            Assert.True(expected.TryGetValue(name, out string? wanted), $"{name}: index_bench has no edition");
            Assert.Equal(wanted, record.Edition);
            compared++;
        }
        Assert.True(compared >= 24, $"{compared} dictionaries compared, expected at least 24");
    }
}

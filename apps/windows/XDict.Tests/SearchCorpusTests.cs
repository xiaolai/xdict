// Real dictionaries through the search model: OALD folds an accented query to its plain key, a phrase keeps its
// space, and a public suggestion never exposes an internal key.
using XDict.Client;
using XDict.Models;
using Xunit;

public class SearchCorpusTests
{
    [Fact]
    public async Task OaldFoldsAccentsKeepsPhrasesAndNeverSuggestsInternalKeys()
    {
        string corpus = Environment.GetEnvironmentVariable("XDICT_CORPUS")
            ?? throw new InvalidOperationException("XDICT_CORPUS must name the corpus");
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE must name the built service");
        string folder = Path.Combine(corpus, "oald");
        string mdx = Directory.GetFiles(folder, "*.mdx", SearchOption.TopDirectoryOnly).Single();
        using var client = new ServiceClient(service);
        client.Handshake();
        LibraryDictionary record = await LibraryImporter.ImportAsync(client, PackageFinder.Discover(mdx));
        var session = new SearchSession(client);
        Assert.Equal(OpenOutcome.Ready, (await session.OpenAsync([record])).Single().State);

        // The file's key is "cafe"; the accented query folds to it (the plan's "café both ways").
        SearchPage plain = await session.LookupAsync("cafe", null, 0, 10);
        SearchPage accented = await session.LookupAsync("café", null, 0, 10);
        Assert.Contains(plain.Hits, hit => hit.Headword == "cafe");
        SearchHit folded = Assert.Single(accented.Hits, hit => hit.Headword == "cafe");
        Assert.Contains(folded.How, new[] { "folded", "unmarked" });

        SearchPage phrase = await session.LookupAsync("take off", null, 0, 10);
        Assert.True(phrase.Total > 0, "OALD's phrase take off is not found");
        Assert.Contains(phrase.Hits, hit => hit.Headword.Contains(' '));

        IReadOnlyList<string> suggestions = await session.SuggestAsync("a", null, 50);
        Assert.DoesNotContain(suggestions, key => key.Contains('@'));
    }
}

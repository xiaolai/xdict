// The search model: folding both ways, suggestions, and the five unavailable states kept distinct.
using XDict.Client;
using XDict.Models;
using Xunit;

public class SearchSessionTests
{
    [Fact]
    public async Task FoldingSuggestionsAndNoMatch()
    {
        (ServiceClient client, LibraryDictionary record) = await ImportTiny();
        using (client)
        {
            var session = new SearchSession(client);
            IReadOnlyList<OpenOutcome> outcomes = await session.OpenAsync([record]);
            Assert.Equal(OpenOutcome.Ready, Assert.Single(outcomes).State);

            SearchPage folded = await session.LookupAsync("cafe", null, 0, 10);
            Assert.Single(folded.Hits);
            Assert.Equal("café", folded.Hits[0].Headword);
            Assert.Equal("unmarked", folded.Hits[0].How);

            SearchPage exact = await session.LookupAsync("café", null, 0, 10);
            Assert.Equal("exact", exact.Hits[0].How);

            IReadOnlyList<string> suggestions = await session.SuggestAsync("r", null, 10);
            Assert.Equal(new[] { "Run", "run" }, suggestions);

            SearchPage none = await session.LookupAsync("zzzz", null, 0, 10);
            Assert.Equal("noMatch", none.Unavailable);
        }
    }

    [Fact]
    public async Task PagesChainByGeneration()
    {
        (ServiceClient client, LibraryDictionary record) = await ImportTiny();
        using (client)
        {
            var session = new SearchSession(client);
            await session.OpenAsync([record]);
            SearchPage first = await session.LookupAsync("run", null, 0, 1);
            SearchPage second = await session.LookupAsync("run", null, 1, 1, pageGeneration: first.Generation);
            SearchPage third = await session.LookupAsync("run", null, 2, 1, pageGeneration: first.Generation);
            Assert.Equal(3ul, first.Total);
            var keys = new[] { first, second, third }.Select(page => page.Hits.Single()).ToArray();
            Assert.Equal(new[] { "run", "run", "Run" }, keys.Select(hit => hit.Headword));
            Assert.Equal(new uint[] { 0, 1, 0 }, keys.Select(hit => hit.Entry.GetProperty("occurrence").GetUInt32()));
        }
    }

    [Fact]
    public async Task EachDictionaryPaintsAsItAnswers()
    {
        string fixtures = Environment.GetEnvironmentVariable("XDICT_FIXTURES")!;
        string libraryFixtures = Environment.GetEnvironmentVariable("XDICT_LIBRARY_FIXTURES")!;
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")!;
        using var client = new ServiceClient(service);
        client.Handshake();
        LibraryDictionary tiny = await LibraryImporter.ImportAsync(client,
            PackageFinder.Discover(Path.Combine(fixtures, "tiny", "tiny.mdx")));
        LibraryDictionary dropped = await LibraryImporter.ImportAsync(client,
            PackageFinder.Discover(Path.Combine(libraryFixtures, "drop", "dropped.mdx")));
        var session = new SearchSession(client);
        await session.OpenAsync([tiny, dropped]);
        var painted = new List<SearchPage>();
        IReadOnlyList<SearchPage> pages = await session.LookupEachAsync("dropped", null, 10,
            page => { lock (painted) painted.Add(page); });
        Assert.Equal(2, pages.Count);
        Assert.Equal(2, painted.Count);
        Assert.Contains(painted, page => page.Hits.Any(hit => hit.Headword == "dropped"));
    }

    [Fact]
    public async Task TheFiveStatesAreDistinct()
    {
        string fixtures = Environment.GetEnvironmentVariable("XDICT_FIXTURES")!;
        string libraryFixtures = Environment.GetEnvironmentVariable("XDICT_LIBRARY_FIXTURES")!;
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")!;
        using var client = new ServiceClient(service);
        client.Handshake();
        var session = new SearchSession(client);
        string temp = Path.Combine(Path.GetTempPath(), "xdict-search-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        try
        {
            foreach (string name in new[] { "tiny.mdx", "tiny.mdd", "tiny.css" })
                File.Copy(Path.Combine(fixtures, "tiny", name), Path.Combine(temp, name));
            LibraryDictionary unimported = Manual(PackageFinder.Discover(Path.Combine(temp, "tiny.mdx")));
            LibraryDictionary gone = Manual(PackageFinder.Discover(Path.Combine(temp, "tiny.mdx"))) with
            {
                Files = [Manual(PackageFinder.Discover(Path.Combine(temp, "tiny.mdx"))).Files[0] with
                {
                    Path = Path.Combine(temp, "absent.mdx"),
                }],
            };
            IReadOnlyList<OpenOutcome> outcomes = await session.OpenAsync([unimported, gone]);
            Assert.Equal(OpenOutcome.NeedsImport, outcomes[0].State);
            Assert.Equal(OpenOutcome.Missing, outcomes[1].State);

            // A refused file surfaces at import, where its header and volumes are read; open only says needsImport.
            ServiceFailureException unsupported = await Assert.ThrowsAsync<ServiceFailureException>(() =>
                LibraryImporter.ImportAsync(client,
                    PackageFinder.Discover(Path.Combine(libraryFixtures, "refused", "v3", "v3.mdx"))));
            Assert.Equal(OpenOutcome.Unsupported, SearchSession.State(unsupported));
            ServiceFailureException damaged = await Assert.ThrowsAsync<ServiceFailureException>(() =>
                LibraryImporter.ImportAsync(client,
                    PackageFinder.Discover(Path.Combine(libraryFixtures, "refused", "damaged", "damaged.mdx"))));
            Assert.Equal(OpenOutcome.Malformed, SearchSession.State(damaged));
        }
        finally
        {
            Directory.Delete(temp, recursive: true);
        }
    }

    private static async Task<(ServiceClient, LibraryDictionary)> ImportTiny()
    {
        string fixtures = Environment.GetEnvironmentVariable("XDICT_FIXTURES")!;
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")!;
        var client = new ServiceClient(service);
        client.Handshake();
        LibraryDictionary record = await LibraryImporter.ImportAsync(client,
            PackageFinder.Discover(Path.Combine(fixtures, "tiny", "tiny.mdx")));
        return (client, record);
    }

    /// <summary>A record for a package that was never imported: fresh ids, no edition yet.</summary>
    private static LibraryDictionary Manual(PackageFiles package)
    {
        var files = new List<LibraryFile>
        {
            new(Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString(), LibraryRole.Mdx, 0, package.Mdx),
        };
        files.AddRange(package.Volumes.Select((path, order) =>
            new LibraryFile(Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString(), LibraryRole.Mdd, order, path)));
        files.AddRange(package.Sidecars.Select((sidecar, order) =>
            new LibraryFile(Guid.NewGuid().ToString("N"), sidecar.PackagePath, LibraryRole.Sidecar, order, sidecar.Path)));
        return new LibraryDictionary("", "", "", "manual", true, 0, "en", "en", files);
    }
}

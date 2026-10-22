// A file rewritten under the library: a new edition, recognised as changed by its identity, its lineage joined to the
// dictionary it continues only when the reader says so, and split back again.
using XDict.Client;
using XDict.Models;
using Xunit;

public class LibraryLineageTests
{
    [Fact]
    public async Task ARewrittenFileIsANewEditionJoinedOnlyByTheReaderAndSplitBack()
    {
        string fixtures = Environment.GetEnvironmentVariable("XDICT_LIBRARY_FIXTURES")
            ?? throw new InvalidOperationException("XDICT_LIBRARY_FIXTURES must name the generated library fixtures");
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE must name the built service");
        string root = Path.Combine(Path.GetTempPath(), "xdict-lineage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            string path = Path.Combine(root, "d.mdx");
            File.Copy(Path.Combine(fixtures, "rewrite", "first.mdx"), path);
            LibraryDictionary first;
            using (var client = new ServiceClient(service))
            {
                client.Handshake();
                first = await LibraryImporter.ImportAsync(client, PackageFinder.Discover(path));
            }
            Assert.All(LibraryVerifier.Check(first), check => Assert.Equal(LibraryFileState.Ok, check.State));

            File.Copy(Path.Combine(fixtures, "rewrite", "second.mdx"), path, overwrite: true);
            Assert.Contains(LibraryVerifier.Check(first), check => check.State == LibraryFileState.Changed);

            using var reader = new ServiceClient(service);
            reader.Handshake();
            LibraryDictionary second = await LibraryImporter.ImportAsync(
                reader, PackageFinder.Discover(path), existing: first);
            Assert.NotEqual(first.Edition, second.Edition);
            Assert.NotEqual(first.Lineage, second.Lineage);

            string joined = await LibraryJoiner.JoinAsync(reader, second.Edition, first.Lineage);
            Assert.Equal(first.Lineage, joined);
            Assert.Equal(first.Lineage, await LibraryJoiner.LineageOfAsync(reader, second.Edition));

            string split = await LibraryJoiner.SplitAsync(reader, second.Edition, second.Lineage);
            Assert.Equal(second.Lineage, split);
            Assert.Equal(second.Lineage, await LibraryJoiner.LineageOfAsync(reader, second.Edition));

            string libraryPath = Path.Combine(root, "library.json");
            LibraryStore store = LibraryStore.Load(libraryPath);
            store.Add(first);
            store.Add(second);
            store.SetLineage(second.Edition, joined);
            LibraryStore reloaded = LibraryStore.Load(libraryPath);
            Assert.Equal(joined, reloaded.Dictionaries.Single(item => item.Edition == second.Edition).Lineage);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}

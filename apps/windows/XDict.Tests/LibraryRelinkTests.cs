// A package whose folder moved is found again by the MDX's identity, and the relocated files still open ready: a move
// is not a change (ADR-0002; the macOS library's relink, rebuilt on the Windows identity).
using XDict.Client;
using XDict.Contract;
using XDict.Models;
using Xunit;

public class LibraryRelinkTests
{
    [Fact]
    public async Task AMovedFolderIsRelinkedByIdentityAndStillOpens()
    {
        string fixtures = Environment.GetEnvironmentVariable("XDICT_FIXTURES")
            ?? throw new InvalidOperationException("XDICT_FIXTURES must name the generated conformance fixtures");
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE must name the built service");
        string root = Path.Combine(Path.GetTempPath(), "xdict-relink-" + Guid.NewGuid().ToString("N"));
        string before = Path.Combine(root, "before");
        string after = Path.Combine(root, "after");
        Directory.CreateDirectory(before);
        try
        {
            foreach (string name in new[] { "tiny.mdx", "tiny.mdd", "tiny.css" })
                File.Copy(Path.Combine(fixtures, "tiny", name), Path.Combine(before, name));
            LibraryDictionary record;
            using (var imported = new ServiceClient(service))
            {
                imported.Handshake();
                record = await LibraryImporter.ImportAsync(imported, PackageFinder.Discover(Path.Combine(before, "tiny.mdx")));
            }
            Assert.All(record.Files, file => Assert.NotNull(file.Identity));

            // The service that imported is gone: no handle can hold the folder against the move.
            Directory.Move(before, after);
            LibraryDictionary? moved = LibraryRelinker.Relink(record, root);
            Assert.NotNull(moved);
            Assert.All(moved!.Files, file => Assert.StartsWith(after, file.Path, StringComparison.OrdinalIgnoreCase));

            using var client = new ServiceClient(service);
            client.Handshake();
            var observations = moved.Files.Select(file => (object)client.Observe(file.Id, file.Name, file.Path)).ToList();
            var body = new
            {
                package = new
                {
                    mdx = new { file = moved.Files.First(file => file.Role == LibraryRole.Mdx).Id },
                    mdd = moved.Files.Where(file => file.Role == LibraryRole.Mdd).OrderBy(file => file.Order)
                        .Select(file => new { file = file.Id }).ToArray(),
                    sidecars = moved.Files.Where(file => file.Role == LibraryRole.Sidecar).OrderBy(file => file.Order)
                        .Select(file => new { file = file.Id }).ToArray(),
                },
            };
            Reply opened = await client.CallAsync("open", body, observations);
            Assert.Null(opened.Error);
            Assert.Equal("ready", opened.Ok!.Value.GetProperty("type").GetString());
            Assert.Equal(moved.Edition, opened.Ok.Value.GetProperty("edition").GetString());
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }
}

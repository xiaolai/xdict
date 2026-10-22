// The service-wide gate separates classes: while a 128 MiB import holds the one import slot, a lookup on another
// dictionary is admitted and answered. The lookup is issued at the import's first progress report.
using XDict.Client;
using XDict.Contract;
using XDict.Models;
using Xunit;

public class LibraryConcurrencyTests
{
    [Fact]
    public async Task ALookupIsAnsweredWhileABigImportRuns()
    {
        string fixtures = Environment.GetEnvironmentVariable("XDICT_FIXTURES")
            ?? throw new InvalidOperationException("XDICT_FIXTURES must name the generated conformance fixtures");
        string libraryFixtures = Environment.GetEnvironmentVariable("XDICT_LIBRARY_FIXTURES")
            ?? throw new InvalidOperationException("XDICT_LIBRARY_FIXTURES must name the generated library fixtures");
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE must name the built service");
        using var client = new ServiceClient(service);
        client.Handshake();
        LibraryDictionary tiny = await LibraryImporter.ImportAsync(client,
            PackageFinder.Discover(Path.Combine(fixtures, "tiny", "tiny.mdx")));
        string dict = await LibraryInspector.OpenAsync(client, tiny);

        var answered = new TaskCompletionSource<Reply>(TaskCreationOptions.RunContinuationsAsynchronously);
        void Progress(ulong done, ulong total)
        {
            if (done == 0 || done >= total || answered.Task.IsCompleted) return;
            _ = Task.Run(async () =>
            {
                try
                {
                    Reply reply = await client.CallAsync("lookup", new
                    {
                        query = "run",
                        dicts = new[] { dict },
                        options = new { limit = 10, offset = 0u, mode = "reader", generation = (uint?)null },
                    });
                    answered.TrySetResult(reply);
                }
                catch (Exception error)
                {
                    answered.TrySetException(error);
                }
            });
        }
        client.ImportProgress += Progress;
        try
        {
            await LibraryImporter.ImportAsync(client,
                PackageFinder.Discover(Path.Combine(libraryFixtures, "big", "big.mdx")));
        }
        finally
        {
            client.ImportProgress -= Progress;
        }
        Reply reply = await answered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Null(reply.Error);
        Assert.True(reply.Ok!.Value.GetProperty("total").GetUInt64() >= 1);
    }
}

// An import's progress through the production client, and a cancelled import retried to completion: the plan's
// "import with progress, cancel and retry".
using XDict.Client;
using XDict.Models;
using Xunit;

public class LibraryProgressTests
{
    [Fact]
    public async Task AnImportReportsProgressAndACancelledRetryCompletes()
    {
        string fixtures = Environment.GetEnvironmentVariable("XDICT_FIXTURES")
            ?? throw new InvalidOperationException("XDICT_FIXTURES must name the generated conformance fixtures");
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE must name the built service");
        PackageFiles package = PackageFinder.Discover(Path.Combine(fixtures, "tiny", "tiny.mdx"));
        using var client = new ServiceClient(service);
        client.Handshake();

        var events = new List<(ulong Done, ulong Total)>();
        void Collect(ulong done, ulong total) { lock (events) events.Add((done, total)); }
        client.ImportProgress += Collect;
        LibraryDictionary first = await LibraryImporter.ImportAsync(client, package);
        Assert.NotEmpty(events);
        Assert.Contains(events, item => item.Done == item.Total && item.Total > 0);

        using var cancel = new CancellationTokenSource();
        void Stop(ulong done, ulong total) => cancel.Cancel();
        client.ImportProgress += Stop;
        try
        {
            ServiceFailureException failure = await Assert.ThrowsAsync<ServiceFailureException>(
                () => LibraryImporter.ImportAsync(client, package, cancellation: cancel.Token));
            Assert.Equal("cancelled", failure.ErrorType);
        }
        finally
        {
            client.ImportProgress -= Stop;
        }

        LibraryDictionary retried;
        try
        {
            retried = await LibraryImporter.ImportAsync(client, package);
        }
        catch (ServiceFailureException error)
        {
            throw new Xunit.Sdk.XunitException($"retry: {error.ErrorType} {error.Error}");
        }
        Assert.Equal(first.Edition, retried.Edition);
    }
}

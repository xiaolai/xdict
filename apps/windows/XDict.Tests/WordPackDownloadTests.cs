// The word pack's downloads: every file checked against the manifest's size and SHA-256, and a failure, a bad hash
// or a cancellation leaves nothing behind. The production manifest is read from its embedded copy.
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using XDict.Models;
using Xunit;

public class WordPackDownloadTests
{
    private sealed class Fake(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,
            CancellationToken cancellationToken) => Task.FromResult(answer(request));
    }

    private sealed class Inline : IProgress<WordPackProgress>
    {
        public List<WordPackProgress> Reports { get; } = [];
        public void Report(WordPackProgress value) => Reports.Add(value);
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static WordPackSource Source(string file, byte[] bytes) =>
        new(file, file, "https://example.invalid/" + file, Hash(bytes), bytes.Length);

    private static string Temp() => Path.Combine(Path.GetTempPath(), "xdict-word-pack-" + Guid.NewGuid().ToString("N"));

    private static HttpResponseMessage Content(byte[] bytes) =>
        new(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) };

    [Fact]
    public void TheEmbeddedManifestPinsTheSevenHTTPSDownloads()
    {
        IReadOnlyList<WordPackSource> sources = WordPackSources.All();
        Assert.Equal(7, sources.Count);
        Assert.All(sources, source =>
        {
            Assert.StartsWith("https://", source.Url);
            Assert.Equal(64, source.Sha256.Length);
            Assert.True(source.Bytes > 0);
        });
        Assert.Contains(sources, source => source.File == "cmudict.dict");
        Assert.Contains(sources, source => source.File == "oewn-WNDB_License.txt");
        Assert.Contains(sources, source => source.File == "eng.derivational.v1.tsv");
    }

    [Fact]
    public async Task EveryFileIsWrittenOnlyAfterItsSizeAndHashMatch()
    {
        string directory = Temp();
        byte[] first = Encoding.UTF8.GetBytes("first file\n");
        byte[] second = Encoding.UTF8.GetBytes("second file\n");
        var sources = new[] { Source("a.txt", first), Source("b.txt", second) };
        var reports = new Inline();
        try
        {
            IReadOnlyList<string> written = await WordPackSources.DownloadAsync(directory, sources,
                new Fake(request => Content(request.RequestUri!.AbsolutePath.EndsWith("a.txt") ? first : second)),
                reports);
            Assert.Equal(2, written.Count);
            Assert.Equal("first file\n", await File.ReadAllTextAsync(Path.Combine(directory, "a.txt")));
            Assert.Equal("second file\n", await File.ReadAllTextAsync(Path.Combine(directory, "b.txt")));
            Assert.Empty(Directory.GetFiles(directory, "*.part"));
            Assert.Contains(reports.Reports,
                report => report.FilesDone == 2 && report.BytesDone == first.Length + second.Length);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task AHashThatDoesNotMatchTheManifestLeavesNothingBehind()
    {
        string directory = Temp();
        byte[] wanted = Encoding.UTF8.GetBytes("wanted\n");
        byte[] served = Encoding.UTF8.GetBytes("served\n");
        WordPackSource source = Source("a.txt", wanted);
        try
        {
            WordPackDownloadException error = await Assert.ThrowsAsync<WordPackDownloadException>(() =>
                WordPackSources.DownloadAsync(directory, [source], new Fake(_ => Content(served))));
            Assert.Contains("a.txt", error.Message);
            Assert.Contains(Hash(served), error.Message);
            Assert.Contains(source.Sha256, error.Message);
            Assert.Empty(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task AnHTTPRefusalAndAnAnnouncedSizeLeaveNothingBehind()
    {
        string directory = Temp();
        byte[] bytes = Encoding.UTF8.GetBytes("bytes\n");
        WordPackSource source = Source("a.txt", bytes);
        try
        {
            await Assert.ThrowsAsync<WordPackDownloadException>(() => WordPackSources.DownloadAsync(directory, [source],
                new Fake(_ => new HttpResponseMessage(HttpStatusCode.NotFound))));
            Assert.Empty(Directory.GetFiles(directory));

            WordPackSource pinned = source with { Bytes = bytes.Length + 1 };
            await Assert.ThrowsAsync<WordPackDownloadException>(() =>
                WordPackSources.DownloadAsync(directory, [pinned], new Fake(_ => Content(bytes))));
            Assert.Empty(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task ACancellationLeavesNothingBehind()
    {
        string directory = Temp();
        byte[] bytes = Encoding.UTF8.GetBytes("bytes\n");
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        try
        {
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => WordPackSources.DownloadAsync(directory,
                [Source("a.txt", bytes)], new Fake(_ => Content(bytes)), cancellation: cancellation.Token));
            Assert.Empty(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }
}

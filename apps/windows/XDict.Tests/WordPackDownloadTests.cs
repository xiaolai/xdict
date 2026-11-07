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

    /// <summary>A body with no Content-Length: the size check has to count the bytes as they stream, not trust a header.</summary>
    private sealed class Streamed(byte[] bytes) : HttpContent
    {
        protected override async Task SerializeToStreamAsync(Stream stream, System.Net.TransportContext? context)
        {
            await stream.WriteAsync(bytes);
            await stream.FlushAsync();
        }

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }
    }

    /// <summary>A body that writes some bytes and then waits, so a cancellation lands mid-download. It honors the
    /// request's own token, as a real body does: a custom content that ignored it would leave the read pending and the
    /// test would measure the harness, not the download.</summary>
    private sealed class Blocking(byte[] prefix) : HttpContent
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CancellationTokenSource Release { get; } = new();

        protected override Task SerializeToStreamAsync(Stream stream, System.Net.TransportContext? context) =>
            SerializeToStreamAsync(stream, context, CancellationToken.None);

        protected override async Task SerializeToStreamAsync(Stream stream, System.Net.TransportContext? context,
            CancellationToken cancellation)
        {
            await stream.WriteAsync(prefix, cancellation);
            await stream.FlushAsync(cancellation);
            Started.TrySetResult();
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, Release.Token);
            try { await Task.Delay(Timeout.Infinite, linked.Token); }
            catch (OperationCanceledException) { }
        }

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }
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
    public async Task AStreamWithoutALengthIsCountedAsItArrives()
    {
        // No Content-Length: the header check cannot decide this, so the byte counting must. Both directions.
        byte[] bytes = Encoding.UTF8.GetBytes("bytes\n");
        string directory = Temp();
        try
        {
            WordPackSource longer = Source("a.txt", bytes[..^1]);
            var error = await Assert.ThrowsAsync<WordPackDownloadException>(() => WordPackSources.DownloadAsync(
                directory, [longer], new Fake(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new Streamed(bytes) })));
            Assert.Contains("more than", error.Message);
            Assert.Empty(Directory.GetFiles(directory));

            WordPackSource shorter = Source("a.txt", [.. bytes, 0x21]);
            error = await Assert.ThrowsAsync<WordPackDownloadException>(() => WordPackSources.DownloadAsync(
                directory, [shorter], new Fake(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new Streamed(bytes) })));
            Assert.Contains("the download is", error.Message);
            Assert.Empty(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task AFailureAfterACompletedFileRemovesThatFileToo()
    {
        // The first file completes and the second fails: a cleanup that only removed the in-flight partial would leave
        // the completed file behind, and every one-file failure test would still pass.
        string directory = Temp();
        byte[] first = Encoding.UTF8.GetBytes("first file\n");
        byte[] second = Encoding.UTF8.GetBytes("second file\n");
        var sources = new[] { Source("a.txt", first), Source("b.txt", second) };
        try
        {
            await Assert.ThrowsAsync<WordPackDownloadException>(() => WordPackSources.DownloadAsync(directory, sources,
                new Fake(request => request.RequestUri!.AbsolutePath.EndsWith("a.txt")
                    ? Content(first)
                    : Content(second[..^1]))));
            Assert.Empty(Directory.GetFiles(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task ACancellationBeforeTheDownloadLeavesNothingBehind()
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

    [Fact]
    public async Task ACancellationDuringTheDownloadLeavesNothingBehind()
    {
        string directory = Temp();
        byte[] bytes = Encoding.UTF8.GetBytes("partial bytes\n");
        var body = new Blocking(bytes);
        using var cancellation = new CancellationTokenSource();
        try
        {
            Task<IReadOnlyList<string>> download = WordPackSources.DownloadAsync(directory,
                [Source("a.txt", [.. bytes, 0x21])],
                new Fake(_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = body }),
                cancellation: cancellation.Token);
            await body.Started.Task.WaitAsync(TimeSpan.FromSeconds(10));
            cancellation.Cancel();
            // A synthetic HttpMessageHandler's body never sees the token a later read passes (only the one the send
            // was given), so the body is released as well: the download ends on its own, exactly as a short response
            // would, and what is asserted is the cleanup of the part already written.
            body.Release.Cancel();
            Task finished = await Task.WhenAny(download, Task.Delay(TimeSpan.FromSeconds(20)));
            Assert.Same(download, finished);
            // The read may end as a cancellation or as a short download; both are the download ending, and what this
            // test is about is that nothing stays on disk.
            Exception? error = await Record.ExceptionAsync(() => download);
            Assert.True(error is OperationCanceledException or WordPackDownloadException,
                "the download ended with " + (error?.GetType().Name ?? "no error"));
            Assert.Empty(Directory.GetFiles(directory));
        }
        finally
        {
            body.Release.Cancel();
            Directory.Delete(directory, true);
        }
    }
}

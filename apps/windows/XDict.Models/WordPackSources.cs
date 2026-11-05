// The word pack's pinned sources: the manifest the app ships, the seven downloads it names, and the check every
// byte passes before the service sees it. The network is the shell's (ADR-0003); no URL ever crosses the pipe.
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;

namespace XDict.Models;

/// <summary>One file the manifest pins: its name, URL, size and SHA-256. Notices are pinned beside their source.</summary>
public sealed record WordPackSource(string Id, string File, string Url, string Sha256, long Bytes);

/// <summary>How far a download is: files complete, and bytes of the whole set.</summary>
public sealed record WordPackProgress(int FilesDone, int FilesTotal, long BytesDone, long BytesTotal);

/// <summary>A download or a check that refused the file; the sentence names the file and what was expected.</summary>
public sealed class WordPackDownloadException(string message) : Exception(message);

public static class WordPackSources
{
    private const string Resource = "XDict.Models.word-pack-sources.json";

    /// <summary>The manifest exactly as embedded, for the service's build (it reads its own copy of the file).</summary>
    public static string ManifestText { get; } = ReadManifest();

    /// <summary>Every pinned source and notice, in manifest order; a source the manifest leaves underived has no URL.</summary>
    public static IReadOnlyList<WordPackSource> All() => Pinned.Value;

    private static readonly Lazy<IReadOnlyList<WordPackSource>> Pinned = new(() => Parse(ManifestText));

    private static string ReadManifest()
    {
        using Stream stream = typeof(WordPackSources).Assembly.GetManifestResourceStream(Resource)
            ?? throw new InvalidOperationException("the word pack manifest is not embedded");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    /// <summary>The pinned entries, each with its URL, hash and byte count; an entry without a download is skipped.</summary>
    public static IReadOnlyList<WordPackSource> Parse(string manifest)
    {
        using JsonDocument document = JsonDocument.Parse(manifest);
        var sources = new List<WordPackSource>();
        var files = new HashSet<string>(StringComparer.Ordinal);
        void Add(string id, JsonElement entry)
        {
            if (!entry.TryGetProperty("file", out JsonElement file) ||
                !entry.TryGetProperty("url", out JsonElement url) ||
                !entry.TryGetProperty("sha256", out JsonElement sha) ||
                !entry.TryGetProperty("bytes", out JsonElement bytes)) return;
            string name = file.GetString() ?? "";
            if (!Plain(name) || !files.Add(name))
                throw new InvalidOperationException($"the word pack manifest names {name} twice or unsafely");
            sources.Add(new WordPackSource(id, name, url.GetString() ?? "", sha.GetString() ?? "", bytes.GetInt64()));
        }
        foreach (JsonElement source in document.RootElement.GetProperty("sources").EnumerateArray())
        {
            string id = source.TryGetProperty("id", out JsonElement held) ? held.GetString() ?? "" : "";
            Add(id, source);
            if (!source.TryGetProperty("notice_files", out JsonElement notices)) continue;
            foreach (JsonElement notice in notices.EnumerateArray()) Add(id + ":notice", notice);
        }
        return sources;
    }

    /// <summary>
    /// Downloads every entry into <paramref name="directory"/>, one `.part` at a time, and keeps a file only after its
    /// size and SHA-256 match the manifest. Any failure or cancellation removes every file this run wrote.
    /// </summary>
    public static async Task<IReadOnlyList<string>> DownloadAsync(string directory,
        IReadOnlyList<WordPackSource> sources, HttpMessageHandler? handler = null,
        IProgress<WordPackProgress>? progress = null, CancellationToken cancellation = default)
    {
        Directory.CreateDirectory(directory);
        long totalBytes = sources.Sum(source => source.Bytes);
        long doneBytes = 0;
        var written = new List<string>();
        using var http = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        http.Timeout = Timeout.InfiniteTimeSpan;
        http.DefaultRequestHeaders.UserAgent.ParseAdd("XDict/0.4");
        try
        {
            for (int index = 0; index < sources.Count; index++)
            {
                cancellation.ThrowIfCancellationRequested();
                WordPackSource source = sources[index];
                Uri uri = new(source.Url, UriKind.Absolute);
                if (uri.Scheme != Uri.UriSchemeHttps)
                    throw new WordPackDownloadException($"{source.File}: {source.Url} is not an HTTPS address");
                string final = Path.Combine(directory, source.File);
                string partial = final + ".part";
                long before = doneBytes;
                try
                {
                    using HttpResponseMessage response = await http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead,
                        cancellation);
                    if (!response.IsSuccessStatusCode)
                        throw new WordPackDownloadException(
                            $"{source.File}: {source.Url} answered HTTP {(int)response.StatusCode}");
                    if (response.Content.Headers.ContentLength is long announced && announced != source.Bytes)
                        throw new WordPackDownloadException(
                            $"{source.File}: the server sends {announced} bytes, the manifest pins {source.Bytes}");
                    await using Stream stream = await response.Content.ReadAsStreamAsync(cancellation);
                    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                    long read = 0;
                    using (var file = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None,
                               64 * 1024, FileOptions.Asynchronous))
                    {
                        byte[] buffer = new byte[64 * 1024];
                        int count;
                        while ((count = await stream.ReadAsync(buffer, cancellation)) > 0)
                        {
                            read += count;
                            if (read > source.Bytes)
                                throw new WordPackDownloadException(
                                    $"{source.File}: the server sends more than the {source.Bytes} bytes pinned");
                            await file.WriteAsync(buffer.AsMemory(0, count), cancellation);
                            hash.AppendData(buffer, 0, count);
                            doneBytes += count;
                            if (doneBytes - before >= 1 << 20)
                            {
                                progress?.Report(new WordPackProgress(index, sources.Count, doneBytes, totalBytes));
                                before = doneBytes;
                            }
                        }
                        await file.FlushAsync(cancellation);
                    }
                    if (read != source.Bytes)
                        throw new WordPackDownloadException(
                            $"{source.File}: the download is {read} bytes, the manifest pins {source.Bytes}");
                    string actual = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
                    if (!actual.Equals(source.Sha256, StringComparison.OrdinalIgnoreCase))
                        throw new WordPackDownloadException(
                            $"{source.File}: its SHA-256 is {actual}, the manifest pins {source.Sha256}");
                    File.Move(partial, final, overwrite: true);
                    written.Add(final);
                    progress?.Report(new WordPackProgress(index + 1, sources.Count, doneBytes, totalBytes));
                }
                catch
                {
                    if (File.Exists(partial)) File.Delete(partial);
                    throw;
                }
            }
            return written;
        }
        catch
        {
            // A failed or cancelled set leaves nothing behind: the next attempt starts from the manifest.
            foreach (string file in written)
            {
                try { File.Delete(file); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            }
            throw;
        }
    }

    private static bool Plain(string name)
    {
        if (name.Length == 0 || !char.IsAsciiLetterOrDigit(name[0])) return false;
        return name.All(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-');
    }
}

// The app's production client: per-class credits, generation cancellation, deadlines and restart/reopen.
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32.SafeHandles;
using System.ComponentModel;
using XDict.Contract;

namespace XDict.Client;

public sealed class ServiceFailureException(string type, JsonElement? error = null) : Exception(type)
{
    public string ErrorType { get; } = type;

    /// <summary>The service's whole error object: the type, and the typed payload the sentence depends on.</summary>
    public JsonElement? Error { get; } = error;
}

public sealed record ServiceClientOptions
{
    public string Storage { get; init; } = "service";
    public TimeSpan LookupDeadline { get; init; } = TimeSpan.FromSeconds(10);
    public TimeSpan BulkDeadline { get; init; } = TimeSpan.FromSeconds(30);
    internal string Arguments { get; init; } = "";
}

public sealed class RequestGeneration
{
    internal readonly CancellationTokenSource Cancellation = new();
    internal CancellationToken Token => Cancellation.Token;
}

/// <summary>The identity of whatever is at a path now, for the library's relink: the same tuple the service compares.</summary>
public static class FileIdentityReader
{
    public static FileIdentity? Observe(string path) => Native.ObservePath(path);
}

public sealed class ServiceClient : IDisposable
{
    private readonly string executable;
    private readonly ServiceClientOptions options;
    private readonly object state = new();
    private readonly Dictionary<string, RequestGeneration> generations = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (string Name, string Path, SafeFileHandle Held)> paths = new(StringComparer.Ordinal);
    private readonly Dictionary<string, OpenPackage> opened = new(StringComparer.Ordinal);
    private ServiceConnection? connection;
    private bool disposed;
    private long nextId;
    private int queued;

    private sealed record OpenPackage(JsonNode Body, IReadOnlyList<object> Files, ServiceConnection Connection, string Remote, string Edition);

    public ServiceClient(string executable, ServiceClientOptions? options = null)
    {
        this.executable = Path.GetFullPath(executable);
        this.options = options ?? new ServiceClientOptions();
        _ = Connection();
    }

    public int ProcessId => Connection().Child.ProcessId;
    internal SafeFileHandle RequestPipe => ((FileStream)Connection().Child.Input).SafeFileHandle;
    public ulong LastRequestId => (ulong)Interlocked.Read(ref nextId);
    // Request ids and operation names only: useful to prove queued work did not cross the pipe.
    public event Action<ulong, string>? RequestSent;

    /// <summary>An import's bytes read and its total, as the service reports them (`done` of `total`).</summary>
    public event Action<ulong, ulong>? ImportProgress;

    public RequestGeneration NewGeneration(string scope)
    {
        lock (state)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (generations.Remove(scope, out var previous)) previous.Cancellation.Cancel();
            var generation = new RequestGeneration();
            generations.Add(scope, generation);
            return generation;
        }
    }

    public FileObservation Observe(string id, string name, string path)
    {
        lock (state)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            SafeFileHandle held = Native.OpenFile(path);
            if (paths.Remove(id, out var previous)) previous.Held.Dispose();
            paths[id] = (name, path, held);
            return new FileObservation(id, name, 0, Native.ObservePath(path), (ulong)Stopwatch.GetTimestamp());
        }
    }

    public Versions Handshake()
    {
        Reply reply = Call("versions", null);
        if (reply.Error is { } error) throw new ServiceFailureException(error.GetProperty("type").GetString()!);
        if (reply.Ok is null) throw new ServiceFailureException("closed");
        Versions versions = reply.Ok.Value.Deserialize<Versions>(Wire.Options)
            ?? throw new ContractViolationException("no versions in the answer");
        if (versions.Protocol != 1) throw new ContractViolationException("incompatible core protocol");
        return versions;
    }

    public Reply Call(string operation, object? body, IReadOnlyList<object>? files = null) =>
        CallAsync(operation, body, files).GetAwaiter().GetResult();

    public Reply CallWithContract(uint contract, string operation, object? body, IReadOnlyList<object>? files = null) =>
        Execute(contract, operation, body, files, null, CancellationToken.None).GetAwaiter().GetResult();

    public Task<Reply> CallAsync(string operation, object? body, IReadOnlyList<object>? files = null,
        RequestGeneration? generation = null, CancellationToken cancellation = default) =>
        Execute(Wire.Version, operation, body, files, generation, cancellation);

    private ServiceConnection Connection()
    {
        lock (state)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (connection is null || !connection.IsAlive)
            {
                connection?.Dispose();
                try
                {
                    connection = new ServiceConnection(executable, options.Storage, options.Arguments);
                    connection.Progress += (_, done, total) => ImportProgress?.Invoke(done, total);
                }
                catch (Exception e) when (e is Win32Exception or FileNotFoundException or UnauthorizedAccessException)
                { throw new ServiceFailureException("closed"); }
            }
            return connection;
        }
    }

    private async Task<Reply> Execute(uint contract, string operation, object? body, IReadOnlyList<object>? files,
        RequestGeneration? generation, CancellationToken cancellation)
    {
        ulong id = (ulong)Interlocked.Increment(ref nextId);
        long started = Stopwatch.GetTimestamp();
        if (Interlocked.Increment(ref queued) > 64)
        {
            Interlocked.Decrement(ref queued);
            return Error(id, "busy");
        }
        ServiceConnection? current = null;
        SemaphoreSlim? credit = null;
        bool acquired = false, sent = false;
        using var timeout = new CancellationTokenSource();
        // health scans every record of the whole MDX; it is bulk work, not a lookup, and a lookup deadline killed
        // the service mid-scan on the multi-million-record dictionaries.
        TimeSpan deadline = operation is "entry" or "resource" or "health" ? options.BulkDeadline : options.LookupDeadline;
        if (operation != "import") timeout.CancelAfter(deadline);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, generation?.Token ?? default, timeout.Token);
        CancellationToken token = linked.Token;
        try
        {
            token.ThrowIfCancellationRequested();
            current = Connection();
            credit = operation == "import" ? current.Imports : operation is "entry" or "resource" ? current.Bulk : current.Lookup;
            await credit.WaitAsync(token).ConfigureAwait(false);
            acquired = true;
            JsonNode? requestBody = JsonSerializer.SerializeToNode(body, Wire.Options);
            IReadOnlyList<object> requestFiles = files ?? Array.Empty<object>();
            if (contract == Wire.Version && operation is not ("versions" or "import" or "open"))
            {
                await current.Restore.WaitAsync(token).ConfigureAwait(false);
                try
                {
                    var required = new List<object>(requestFiles);
                    foreach (string dict in DictionaryIds(requestBody).ToArray())
                    {
                        OpenPackage? package;
                        lock (state) opened.TryGetValue(dict, out package);
                        if (package is null) continue;
                        if (package.Connection != current)
                        {
                            ulong reopenId = (ulong)Interlocked.Increment(ref nextId);
                            Reply reopened = await current.Send(Wire.Version, reopenId, "open", package.Body,
                                () => Materialize(current, package.Files), () => { }, token).WaitAsync(token).ConfigureAwait(false);
                            if (reopened.Error is { } reopenError)
                                return Error(id, reopenError.GetProperty("type").GetString() ?? "staleHandle");
                            if (reopened.Ok?.GetProperty("type").GetString() != "ready")
                                return Error(id, "needsImport");
                            if (reopened.Ok.Value.GetProperty("edition").GetString() != package.Edition)
                                return Error(id, "sourceChanged");
                            package = package with { Connection = current, Remote = reopened.Ok.Value.GetProperty("dict").GetString()! };
                            lock (state) opened[dict] = package;
                        }
                        ReplaceDictionary(requestBody, dict, package.Remote);
                        required.AddRange(package.Files);
                    }
                    requestFiles = required.OfType<FileObservation>().DistinctBy(file => file.Id).Cast<object>()
                        .Concat(required.Where(file => file is not FileObservation)).ToArray();
                }
                finally { current.Restore.Release(); }
            }
            Reply reply = await current.Send(contract, id, operation, requestBody,
                () => Materialize(current, requestFiles), () => { sent = true; RequestSent?.Invoke(id, operation); }, token).WaitAsync(token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested(); // A completed late reply cannot publish a superseded generation.
            if (operation == "open" && reply.Ok is { ValueKind: JsonValueKind.Object } ok && ok.GetProperty("type").GetString() == "ready")
            {
                string dict = ok.GetProperty("dict").GetString()!;
                lock (state) opened[dict] = new OpenPackage(requestBody!, requestFiles, current, dict, ok.GetProperty("edition").GetString()!);
            }
            if (operation == "close" && reply.Error is null)
                lock (state) foreach (string dict in DictionaryIds(JsonSerializer.SerializeToNode(body, Wire.Options))) opened.Remove(dict);
            if (reply.Ok is { } answer)
            {
                JsonNode? normalized = JsonNode.Parse(answer.GetRawText());
                lock (state)
                    foreach (var package in opened)
                        NormalizeDictionaries(normalized, package.Value.Remote, package.Key);
                reply = reply with { Ok = JsonSerializer.SerializeToElement(normalized, Wire.Options) };
            }
            return reply;
        }
        catch (OperationCanceledException)
        {
            if (timeout.IsCancellationRequested && sent) current?.Dispose();
            else if (sent && operation != "import") current?.Abandon(id, deadline - Stopwatch.GetElapsedTime(started));
            // Import cancellation must reach the core's progress flag even when the caller stops waiting. The reply is
            // awaited: a busy or closed queue answers with a typed error, which a discarded fire-and-forget call hid.
            if (operation == "import" && sent && current is not null && current.IsAlive)
            {
                for (int attempt = 0; attempt < 3; attempt++)
                {
                    Reply cancelled = await CallAsync("cancel", new { id }, cancellation: CancellationToken.None)
                        .ConfigureAwait(false);
                    if (cancelled.Error is null) break;
                    await Task.Delay(50).ConfigureAwait(false);
                }
            }
            return Error(id, timeout.IsCancellationRequested ? "deadline" : "cancelled");
        }
        catch (ServiceFailureException error) { return Error(id, error.ErrorType); }
        catch (Exception e) when (e is IOException or ObjectDisposedException)
        {
            current?.Dispose();
            return Error(id, "staleHandle");
        }
        catch (ContractViolationException)
        {
            // The service answered something the contract does not allow: retrying it as a restart would hide the bug.
            current?.Dispose();
            return Error(id, "contractMismatch");
        }
        catch (JsonException)
        {
            current?.Dispose();
            return Error(id, "internal");
        }
        finally
        {
            if (acquired) credit!.Release();
            Interlocked.Decrement(ref queued);
        }
    }

    private IReadOnlyList<object> Materialize(ServiceConnection current, IReadOnlyList<object> files)
    {
        lock (state) return files.Select(file =>
        {
            if (file is not FileObservation observation || !paths.TryGetValue(observation.Id, out var path)) return file;
            return new FileObservation(observation.Id, path.Name, Native.DuplicateFile(current.Child.ProcessHandle, path.Held),
                Native.ObservePath(path.Path), (ulong)Stopwatch.GetTimestamp());
        }).ToArray();
    }

    private static IEnumerable<string> DictionaryIds(JsonNode? body)
    {
        if (body is not JsonObject obj) yield break;
        if (obj["dict"] is JsonValue value && value.TryGetValue(out string? dict)) yield return dict;
        if (obj["dicts"] is JsonArray dicts)
            foreach (JsonNode? item in dicts) if (item is not null) yield return item.GetValue<string>();
    }

    private static void ReplaceDictionary(JsonNode? body, string original, string remote)
    {
        if (body is not JsonObject obj) return;
        if (obj["dict"]?.GetValue<string>() == original) obj["dict"] = remote;
        if (obj["dicts"] is JsonArray dicts)
            for (int i = 0; i < dicts.Count; i++) if (dicts[i]?.GetValue<string>() == original) dicts[i] = remote;
    }

    private static Reply Error(ulong id, string type) => new(Wire.Version, id, null, JsonSerializer.SerializeToElement(new { type }));

    private static void NormalizeDictionaries(JsonNode? node, string remote, string logical)
    {
        if (node is JsonObject obj)
        {
            ReplaceDictionary(obj, remote, logical);
            foreach (var property in obj.ToArray()) NormalizeDictionaries(property.Value, remote, logical);
        }
        else if (node is JsonArray array)
            foreach (var item in array) NormalizeDictionaries(item, remote, logical);
    }

    public void Dispose()
    {
        lock (state)
        {
            if (disposed) return;
            disposed = true;
            foreach (var generation in generations.Values) generation.Cancellation.Cancel();
            connection?.Dispose();
            foreach (var path in paths.Values) path.Held.Dispose();
            paths.Clear();
        }
    }
}

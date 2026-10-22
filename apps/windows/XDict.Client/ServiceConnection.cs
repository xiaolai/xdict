// One spawn and its pipes. A single reader demultiplexes replies; the writer lock covers complete frames.
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using XDict.Contract;

namespace XDict.Client;

internal sealed class ServiceConnection : IDisposable
{
    internal readonly ChildProcess Child;
    internal readonly SemaphoreSlim Lookup = new(8), Bulk = new(2), Imports = new(1), Restore = new(1);
    internal event Action<ulong, ulong, ulong>? Progress;
    private readonly SemaphoreSlim writer = new(1);
    private readonly ConcurrentDictionary<ulong, TaskCompletionSource<Reply>> pending = new();
    private int stopped;
    internal bool IsAlive => Volatile.Read(ref stopped) == 0 && Native.WaitForSingleObject(Child.ProcessHandle, 0) != 0;

    internal ServiceConnection(string executable, string storage, string arguments)
    {
        Child = Native.Spawn(executable, storage, arguments);
        _ = Task.Run(ReadReplies);
        _ = Task.Run(() =>
        {
            try
            {
                using var reader = new StreamReader(Child.Errors, Encoding.UTF8);
                while (reader.ReadLine() is { } line) Debug.WriteLine("service: " + line);
            }
            catch (Exception e) when (e is IOException or ObjectDisposedException) { }
        });
    }

    internal async Task<Reply> Send(uint contract, ulong id, string operation, object? body,
        Func<IReadOnlyList<object>> files, Action sent, CancellationToken cancellation)
    {
        var completion = new TaskCompletionSource<Reply>(TaskCreationOptions.RunContinuationsAsynchronously);
        await writer.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            cancellation.ThrowIfCancellationRequested();
            if (!IsAlive) throw new IOException("the service stopped");
            // File handles are duplicated only after queue admission, never for superseded queued requests.
            byte[] payload = JsonSerializer.SerializeToUtf8Bytes(new
            {
                contract, id, op = operation, files = files(), operation = body,
            }, Wire.Options);
            if (payload.Length > Wire.JsonMax) throw new ContractViolationException("the request is over the JSON limit");
            if (!pending.TryAdd(id, completion)) throw new ContractViolationException("a request id was reused");
            sent();
            // Anonymous pipes are synchronous handles. Keep blocking I/O off the caller's (possibly UI) thread.
            await Task.Run(() =>
            {
                Child.Input.Write(BitConverter.GetBytes((uint)payload.Length));
                Child.Input.WriteByte(1);
                Child.Input.Write(payload);
                Child.Input.Flush();
            }, CancellationToken.None).ConfigureAwait(false);
        }
        finally { writer.Release(); }
        Reply reply = await completion.Task.WaitAsync(cancellation).ConfigureAwait(false);
        if (reply.Error is { } error && error.GetProperty("type").GetString() == "contractMismatch" &&
            (error.GetProperty("contract").GetUInt32() != contract || error.GetProperty("service").GetUInt32() != reply.Contract))
            throw new ContractViolationException("inconsistent contract mismatch");
        return reply;
    }

    private void ReadReplies()
    {
        try
        {
            while (Volatile.Read(ref stopped) == 0)
            {
                byte[] bytes = ReadFrame(1, Wire.JsonMax);
                using JsonDocument document = JsonDocument.Parse(bytes);
                JsonElement root = document.RootElement;
                if (root.TryGetProperty("event", out JsonElement eventKind))
                {
                    if (eventKind.GetString() == "progress")
                        Progress?.Invoke(root.GetProperty("id").GetUInt64(), root.GetProperty("done").GetUInt64(),
                            root.GetProperty("total").GetUInt64());
                    continue;
                }
                Validate.Reply(root);
                ulong id = root.GetProperty("id").GetUInt64();
                JsonElement? ok = root.TryGetProperty("ok", out JsonElement answer) ? answer.Clone() : null;
                JsonElement? error = root.TryGetProperty("error", out JsonElement failure) ? failure.Clone() : null;
                uint contract = root.GetProperty("contract").GetUInt32();
                bool mismatch = error is { } failureRecord && failureRecord.GetProperty("type").GetString() == "contractMismatch";
                if (contract != Wire.Version && !mismatch) throw new ContractViolationException("the reply speaks another contract");
                byte[]? payload = null;
                if (ok is { ValueKind: JsonValueKind.Object } record && record.TryGetProperty("bulk", out JsonElement bulk))
                {
                    ulong length = bulk.GetProperty("length").GetUInt64();
                    ulong transfer = bulk.GetProperty("transfer").GetUInt64();
                    if (length > Wire.BulkMax || transfer != id) throw new ContractViolationException("invalid bulk announcement");
                    byte[] frame = ReadFrame(2, Wire.BulkMax + 8);
                    if (frame.Length < 8 || (ulong)(frame.Length - 8) != length || BitConverter.ToUInt64(frame) != id)
                        throw new ContractViolationException("the bulk frame does not match its announcement");
                    payload = frame[8..];
                }
                if (!pending.TryRemove(id, out TaskCompletionSource<Reply>? completion))
                    throw new ContractViolationException("the reply names an unknown request");
                completion.TrySetResult(new Reply(contract, id, ok, error, payload));
            }
        }
        catch (Exception e)
        {
            // Anything the reply loop cannot read is the connection's end, including a KeyNotFoundException from a
            // reply shape this reader does not know: a faulted task that never called Fail left IsAlive true.
            Fail(e);
        }
    }

    private byte[] ReadFrame(int expectedKind, int maximum)
    {
        byte[] header = new byte[4];
        Child.Output.ReadExactly(header);
        uint length = BitConverter.ToUInt32(header);
        int kind = Child.Output.ReadByte();
        if (length > maximum || kind != expectedKind) throw new ContractViolationException("invalid frame kind or length");
        byte[] payload = new byte[length];
        Child.Output.ReadExactly(payload);
        return payload;
    }

    internal void Abandon(ulong id, TimeSpan remaining)
    {
        if (pending.TryGetValue(id, out var completion)) _ = ReclaimAbandoned(completion.Task, remaining);
    }

    private async Task ReclaimAbandoned(Task<Reply> reply, TimeSpan remaining)
    {
        try { await reply.WaitAsync(remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero).ConfigureAwait(false); }
        catch (TimeoutException) { Dispose(); }
        catch (Exception) { /* The reader has already failed this connection. */ }
    }

    private void Fail(Exception error)
    {
        Interlocked.Exchange(ref stopped, 1);
        foreach (var pair in pending)
            if (pending.TryRemove(pair.Key, out var completion)) completion.TrySetException(error);
    }

    public void Dispose()
    {
        Fail(new IOException("the service connection closed"));
        Child.Abort();
    }
}

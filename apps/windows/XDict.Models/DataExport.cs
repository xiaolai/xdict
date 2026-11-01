// The export and erase model: the log's JSON written whole to the reader's chosen file, and erase as a rewrite whose
// receipt is the core's actual counts. Erase is never retried automatically: a lost acknowledgement is settled by a
// fresh export or state read, so a second call cannot delete a second log.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;

namespace XDict.Models;

public sealed record DataExportResult(string Path, long Bytes);

public sealed class DataExport(ServiceClient client)
{
    public async Task<DataExportResult> ExportAsync(string path, CancellationToken cancellation = default)
    {
        Reply reply = await client.CallAsync("exportData", null, cancellation: cancellation).ConfigureAwait(false);
        if (reply.Error is { } error)
            throw new ServiceFailureException(error.TryGetProperty("type", out JsonElement kind)
                ? kind.GetString() ?? "internal"
                : "internal", error);
        byte[] bytes = reply.Payload ?? throw new InvalidOperationException("the export carried no bytes");
        string full = System.IO.Path.GetFullPath(path);
        string? folder = System.IO.Path.GetDirectoryName(full);
        if (folder is not null) Directory.CreateDirectory(folder);
        string temporary = full + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await File.WriteAllBytesAsync(temporary, bytes, cancellation).ConfigureAwait(false);
            File.Move(temporary, full, true);
        }
        finally
        {
            File.Delete(temporary);
        }
        return new DataExportResult(full, bytes.LongLength);
    }

    public async Task<EraseReport> EraseAsync(Func<double>? now = null, Func<string>? device = null,
        CancellationToken cancellation = default)
    {
        var body = new
        {
            stamp = new
            {
                at = (now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeSeconds()))(),
                device = (device ?? (() => DeviceIdentity.Current()))(),
            },
            operation = "erase:" + Guid.NewGuid().ToString("N"),
        };
        return StudyWire.Read<EraseReport>(
            await client.CallAsync("eraseData", body, cancellation: cancellation).ConfigureAwait(false));
    }
}

// One sync pass from the app's side (contract 3): list the reader's folder logs, observe each read-only, open the
// destination as the one writable handle, and let the service merge and stage. The final log replaces the old one
// only by an atomic rename after the reply; a failure leaves the old log and deletes the temporary.
using XDict.Client;
using XDict.Contract;

namespace XDict.Models;

/// <summary>The core's report for one pass.</summary>
public sealed record SyncReport(ulong Exported, ulong Peers, ulong Added, ulong Skipped);

/// <summary>The folder or one file is outside the contract's sync bounds; the message names the file or folder.</summary>
public sealed class SyncLimitException(string message) : Exception(message);

public sealed class SyncSession(ServiceClient client, Func<string>? device = null)
{
    public const int MaxFiles = 64;
    public const long MaxBytes = 256L * 1024 * 1024;

    private readonly Func<string> device = device ?? (() => DeviceIdentity.Current());

    public async Task<SyncReport> SyncAsync(string folder, CancellationToken cancellation = default)
    {
        string name = device();
        if (name.Length == 0 || name.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('-' or '_')))
            throw new ArgumentException($"a device name for a file: {name}", nameof(folder));
        string full = Path.GetFullPath(folder);
        if (!Directory.Exists(full)) throw new DirectoryNotFoundException(full);
        string own = "xdict-" + name + ".xdlog";
        List<string> inputs = Directory.EnumerateFiles(full, "*.xdlog", SearchOption.TopDirectoryOnly)
            .Where(path => !string.Equals(Path.GetFileName(path), own, StringComparison.OrdinalIgnoreCase))
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (inputs.Count > MaxFiles)
            throw new SyncLimitException($"{full}: {inputs.Count} logs; the bound is {MaxFiles}");
        long aggregate = 0;
        var observations = new List<object>();
        for (int index = 0; index < inputs.Count; index++)
        {
            string path = inputs[index];
            long size = new FileInfo(path).Length;
            if (size > MaxBytes) throw new SyncLimitException($"{path}: {size} bytes; the bound is {MaxBytes}");
            aggregate = checked(aggregate + size);
            if (aggregate > MaxBytes)
                throw new SyncLimitException($"{path}: the folder's logs exceed {MaxBytes} bytes");
            observations.Add(client.Observe("sync-" + index, Path.GetFileName(path), path));
        }
        string final = Path.Combine(full, own);
        string temporary = final + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            observations.Add(client.ObserveWrite("sync-output", own, temporary));
            Reply reply = await client.CallAsync("ledgerSync", new { device = name },
                observations, cancellation: cancellation).ConfigureAwait(false);
            // The app's own handle must close before the destination is replaced; the service's duplicate already has.
            client.Release("sync-output");
            SyncReport report = StudyWire.Read<SyncReport>(reply);
            File.Move(temporary, final, true);
            return report;
        }
        finally
        {
            client.Release("sync-output");
            for (int index = 0; index < inputs.Count; index++) client.Release("sync-" + index);
            File.Delete(temporary);
        }
    }
}

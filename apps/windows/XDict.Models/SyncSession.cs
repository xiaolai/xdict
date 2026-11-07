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
        // One pass owns every observation id it creates: two passes on one client must not release each other's
        // handles, and a folder listing is I/O that must not run on the caller's dispatcher.
        string pass = Guid.NewGuid().ToString("N");
        string output = "sync-" + pass + "-out";
        var held = new List<string>();
        string? temporary = null;
        try
        {
            List<string> inputs = await Task.Run(() => Inputs(full, own), cancellation).ConfigureAwait(false);
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
                string id = "sync-" + pass + "-" + index;
                observations.Add(client.Observe(id, Path.GetFileName(path), path));
                held.Add(id);
            }
            string final = Path.Combine(full, own);
            temporary = final + "." + pass + ".tmp";
            observations.Add(client.ObserveWrite(output, own, temporary));
            held.Add(output);
            Reply reply = await client.CallAsync("ledgerSync", new { device = name },
                observations, cancellation: cancellation).ConfigureAwait(false);
            // The app's own handle must close before the destination is replaced; the service's duplicate already has.
            client.Release(output);
            held.Remove(output);
            SyncReport report = StudyWire.Read<SyncReport>(reply);
            File.Move(temporary, final, true);
            temporary = null;
            return report;
        }
        finally
        {
            // Every id this pass opened, whether the failure came from an observation, the call or the rename: an
            // exception between two openings must not leave the earlier one in the client's table.
            foreach (string id in held) client.Release(id);
            if (temporary is not null) File.Delete(temporary);
        }
    }

    /// <summary>The logs to merge, at most one past the bound: the listing stops there, so a folder of thousands
    /// costs one metadata pass and no file opens. The bound itself is checked by the caller, which owns the
    /// sentence.</summary>
    private static List<string> Inputs(string full, string own) =>
        Directory.EnumerateFiles(full, "*.xdlog", SearchOption.TopDirectoryOnly)
            .Where(path => !string.Equals(Path.GetFileName(path), own, StringComparison.OrdinalIgnoreCase))
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .Take(MaxFiles + 1)
            .ToList();
}

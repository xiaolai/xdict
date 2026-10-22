// Importing a discovered package through the production service: the files as stable source ids, the reader's
// observations, and the core's edition and lineage back. Cancellation reaches the service's progress flag.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;

namespace XDict.Models;

public static class LibraryImporter
{
    /// <summary>
    /// Imports a discovered package. An existing record keeps its files' ids and names, so a changed file is the same
    /// location to the core — a changed edition, not a new dictionary — and a re-import can recognise it.
    /// </summary>
    public static async Task<LibraryDictionary> ImportAsync(
        ServiceClient client, PackageFiles package, string? displayName = null, CancellationToken cancellation = default,
        LibraryDictionary? existing = null)
    {
        if (package.MissingVolumes.Count > 0) throw new PackageIncompleteException(package.Mdx, package.MissingVolumes);
        string root = Path.GetDirectoryName(package.Mdx) ?? throw new ArgumentException("the MDX has no folder");
        // A file is the same location by its path first; order is only the fallback for a relocated package. Matching
        // by list position alone gave the wrong id when a volume gap was filled or a sidecar inserted ahead.
        var claimed = new HashSet<string>(StringComparer.Ordinal);
        LibraryFile? Known(LibraryRole role, int order, string path)
        {
            LibraryFile? found = existing?.Files.FirstOrDefault(file => file.Role == role &&
                string.Equals(file.Path, path, StringComparison.OrdinalIgnoreCase) && !claimed.Contains(file.Id));
            // The order fallback is for a package that moved, never for a different file in the old file's place:
            // the leaf name must agree, or a new sidecar would inherit the removed one's id and core name.
            found ??= existing?.Files.FirstOrDefault(file => file.Role == role && file.Order == order &&
                string.Equals(Path.GetFileName(file.Path), Path.GetFileName(path), StringComparison.OrdinalIgnoreCase) &&
                !claimed.Contains(file.Id));
            if (found is not null) claimed.Add(found.Id);
            return found;
        }
        LibraryFile Build(LibraryRole role, int order, string path, string? fallbackName = null)
        {
            // One resolution per file: Known claims the record, so a second call for the same file would miss it.
            LibraryFile? known = Known(role, order, path);
            return new LibraryFile(known?.Id ?? Guid.NewGuid().ToString("N"),
                known?.Name ?? fallbackName ?? Guid.NewGuid().ToString(), role, order, path);
        }
        var files = new List<LibraryFile> { Build(LibraryRole.Mdx, 0, package.Mdx) };
        files.AddRange(package.Volumes.Select((path, order) => Build(LibraryRole.Mdd, order, path)));
        files.AddRange(package.Sidecars.Select((sidecar, order) =>
            Build(LibraryRole.Sidecar, order, sidecar.Path, sidecar.PackagePath)));

        var observations = new List<object>();
        for (int index = 0; index < files.Count; index++)
        {
            LibraryFile file = files[index];
            ReparseGuard.Check(file.Path, root);
            FileObservation observation = client.Observe(file.Id, file.Name, file.Path);
            files[index] = file with { Identity = observation.Identity };
            observations.Add(observation);
        }

        var body = new { package = PackageWire.Package(files[0].Id, files), progress = true };
        Reply reply;
        for (int attempt = 0; ; attempt++)
        {
            reply = await client.CallAsync("import", body, observations, cancellation: cancellation);
            // A full service queue is a typed, transient refusal (CONTRACT.md §5): wait and send again.
            if (reply.Error is { } busy && busy.GetProperty("type").GetString() == "busy" && attempt < 20)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(100), cancellation);
                continue;
            }
            break;
        }
        if (reply.Error is { } error)
            throw new ServiceFailureException(error.GetProperty("type").GetString() ?? "internal", error);
        JsonElement answer = reply.Ok ?? throw new InvalidOperationException("the import answered nothing");
        // A volume the core could not read is a problem, not a silent skip: the package is refused with the cause.
        if (answer.TryGetProperty("problems", out JsonElement problems) && problems.ValueKind == JsonValueKind.Array &&
            problems.GetArrayLength() > 0 && problems[0].TryGetProperty("error", out JsonElement cause))
            throw new ServiceFailureException(cause.GetProperty("type").GetString() ?? "unsupported", cause);
        string edition = answer.GetProperty("edition").GetString()!;
        string lineage = answer.GetProperty("lineage").GetString()!;
        JsonElement info = answer.GetProperty("info");
        string title = info.GetProperty("title").GetString()!;
        (string search, string explain) = PackageFinder.GuessLanguages(package.Mdx);
        return new LibraryDictionary(
            edition, lineage, title,
            string.IsNullOrWhiteSpace(displayName) ? title : displayName,
            true, 0, search, explain, files);
    }
}

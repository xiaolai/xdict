// What the reader's details pane shows: the dictionary's health check and its reading-style report, fetched through
// the service while the dictionary is open, then stored beside the record.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;

namespace XDict.Models;

public static class LibraryInspector
{
    public static async Task<LibraryDictionary> InspectAsync(ServiceClient client, LibraryDictionary record,
        CancellationToken cancellation = default)
    {
        string dict = await OpenAsync(client, record, cancellation);
        try
        {
            Reply health = await client.CallAsync("health", new { dict }, cancellation: cancellation);
            Reply style = await client.CallAsync("readingStyle", new { dict }, cancellation: cancellation);
            if (health.Error is { } healthError)
                throw new ServiceFailureException(healthError.GetProperty("type").GetString() ?? "internal", healthError);
            if (style.Error is { } styleError)
                throw new ServiceFailureException(styleError.GetProperty("type").GetString() ?? "internal", styleError);
            Reply closed = await client.CallAsync("close", new { dict }, cancellation: cancellation);
            // A close the service refused leaves its package open; the caller must see that, not assume it closed.
            if (closed.Error is { } closeError)
                throw new ServiceFailureException(closeError.GetProperty("type").GetString() ?? "internal", closeError);
            return record with
            {
                HealthJson = health.Ok?.GetRawText(),
                StyleJson = style.Ok?.GetRawText(),
            };
        }
        catch
        {
            await client.CallAsync("close", new { dict }, cancellation: CancellationToken.None);
            throw;
        }
    }

    /// <summary>Opens the record's package with fresh observations; the service's dictionary handle.</summary>
    public static async Task<string> OpenAsync(ServiceClient client, LibraryDictionary record,
        CancellationToken cancellation = default)
    {
        LibraryFile mdx = record.Files.First(file => file.Role == LibraryRole.Mdx);
        string root = Path.GetDirectoryName(mdx.Path)!;
        var observations = new List<object>();
        foreach (LibraryFile file in record.Files)
        {
            ReparseGuard.Check(file.Path, root);
            observations.Add(client.Observe(file.Id, file.Name, file.Path));
        }
        var body = new { package = PackageWire.Package(mdx.Id, record.Files) };
        Reply opened = await client.CallAsync("open", body, observations, cancellation: cancellation);
        if (opened.Error is { } error)
            throw new ServiceFailureException(error.GetProperty("type").GetString() ?? "internal", error);
        JsonElement ok = opened.Ok ?? throw new InvalidOperationException("open answered nothing");
        if (ok.GetProperty("type").GetString() != "ready")
            throw new ServiceFailureException("needsImport", ok);
        return ok.GetProperty("dict").GetString()!;
    }
}

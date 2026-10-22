// The reader's search: the library's enabled dictionaries opened through the service, a query against a visible
// scope, suggestions, and the five states a dictionary can be unavailable in — kept distinct, never one "error".
using System.ComponentModel;
using System.Text.Json;
using XDict.Client;
using XDict.Contract;

namespace XDict.Models;

public sealed record OpenDictionary(string Edition, string Name, string Handle);

/// <summary>One dictionary's state after opening: ready, or why it is not answering.</summary>
public sealed record OpenOutcome(string Edition, string Name, string State)
{
    public const string Ready = "ready";
    public const string NeedsImport = "needsImport";
    public const string Missing = "missing";
    public const string Malformed = "malformed";
    public const string Unsupported = "unsupported";

    /// <summary>Busy, timed out, closed or speaking another contract: not the same as a file that is not there.</summary>
    public const string Unavailable = "unavailable";
}

public sealed record SearchHit(string Edition, string Dictionary, JsonElement Entry, string Headword, string How,
    IReadOnlyList<string> Problems);

/// <summary>A page of results, and the state that explains an empty one.</summary>
public sealed record SearchPage(IReadOnlyList<SearchHit> Hits, ulong Total, uint Generation, string? Unavailable);

public sealed class SearchSession
{
    private readonly ServiceClient client;
    private readonly Dictionary<string, OpenDictionary> open = [];

    public SearchSession(ServiceClient client) => this.client = client;

    public IReadOnlyCollection<OpenDictionary> Dictionaries => open.Values;

    /// <summary>Opens the enabled dictionaries; a dictionary that cannot open keeps its own state.</summary>
    public async Task<IReadOnlyList<OpenOutcome>> OpenAsync(IEnumerable<LibraryDictionary> library,
        CancellationToken cancellation = default)
    {
        var outcomes = new List<OpenOutcome>();
        var enabled = library.Where(item => item.Enabled).ToList();
        // A dictionary removed from the library or switched off stops answering: its handle is closed and forgotten.
        foreach (string edition in open.Keys.ToList())
        {
            if (enabled.Any(item => item.Edition == edition)) continue;
            OpenDictionary stale = open[edition];
            open.Remove(edition);
            await client.CallAsync("close", new { dict = stale.Handle }, cancellation: CancellationToken.None);
        }
        // A failed (re)open must not leave the previous handle answering: close it and forget it.
        async Task Drop(string edition)
        {
            if (!open.Remove(edition, out OpenDictionary? stale)) return;
            await client.CallAsync("close", new { dict = stale.Handle }, cancellation: CancellationToken.None);
        }
        foreach (LibraryDictionary record in enabled)
        {
            try
            {
                string handle = await LibraryInspector.OpenAsync(client, record, cancellation);
                // A reopen replaces the handle; the previous one is closed so the service holds one package per edition.
                if (open.TryGetValue(record.Edition, out OpenDictionary? previous) && previous.Handle != handle)
                    await client.CallAsync("close", new { dict = previous.Handle }, cancellation: CancellationToken.None);
                open[record.Edition] = new OpenDictionary(record.Edition, record.DisplayName, handle);
                outcomes.Add(new OpenOutcome(record.Edition, record.DisplayName, OpenOutcome.Ready));
            }
            catch (ServiceFailureException error)
            {
                await Drop(record.Edition);
                outcomes.Add(new OpenOutcome(record.Edition, record.DisplayName, State(error)));
            }
            catch (Win32Exception)
            {
                // A share-mode refusal from another program is transient, not a damaged dictionary.
                await Drop(record.Edition);
                outcomes.Add(new OpenOutcome(record.Edition, record.DisplayName, OpenOutcome.Unavailable));
            }
            catch (ReparseRefusedException)
            {
                // A file behind a link is refused by design (the containment rule): it is never opened, and its
                // refusal costs this dictionary its state, not the whole open.
                await Drop(record.Edition);
                outcomes.Add(new OpenOutcome(record.Edition, record.DisplayName, OpenOutcome.Unsupported));
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // A path that is gone or unreadable never reaches the service: the dictionary is missing, not broken.
                await Drop(record.Edition);
                outcomes.Add(new OpenOutcome(record.Edition, record.DisplayName, OpenOutcome.Missing));
            }
            catch (Exception)
            {
                // An unexpected reply shape costs this dictionary its state too (finding 42): one bad record never
                // aborts every dictionary's open.
                await Drop(record.Edition);
                outcomes.Add(new OpenOutcome(record.Edition, record.DisplayName, OpenOutcome.Malformed));
            }
        }
        return outcomes;
    }

    public IReadOnlyList<OpenDictionary> Scope(string? edition) =>
        edition is null ? open.Values.ToList() : open.Values.Where(item => item.Edition == edition).ToList();

    public async Task<SearchPage> LookupAsync(string query, string? edition, uint offset, uint limit,
        uint? pageGeneration = null, RequestGeneration? generation = null, CancellationToken cancellation = default)
    {
        IReadOnlyList<OpenDictionary> scope = Scope(edition);
        if (scope.Count == 0) return new SearchPage([], 0, 0, OpenOutcome.Missing);
        Reply reply = await client.CallAsync("lookup", new
        {
            query,
            dicts = scope.Select(item => item.Handle).ToArray(),
            options = new { limit, offset, mode = "reader", generation = pageGeneration },
        }, generation: generation, cancellation: cancellation);
        if (reply.Error is { } error) return new SearchPage([], 0, 0, State(error));
        JsonElement ok = reply.Ok!.Value;
        var hits = new List<SearchHit>();
        foreach (JsonElement hit in ok.GetProperty("hits").EnumerateArray())
        {
            string handle = hit.GetProperty("dict").GetString()!;
            OpenDictionary dictionary = scope.First(item => item.Handle == handle);
            var problems = hit.GetProperty("problems").EnumerateArray()
                .Select(problem => problem.GetProperty("type").GetString() ?? "").ToArray();
            hits.Add(new SearchHit(dictionary.Edition, dictionary.Name, hit.GetProperty("entry").Clone(),
                hit.GetProperty("headword").GetString() ?? "", hit.GetProperty("how").GetProperty("type").GetString() ?? "",
                problems));
        }
        ulong total = ok.GetProperty("total").GetUInt64();
        uint page = ok.GetProperty("generation").GetUInt32();
        return new SearchPage(hits, total, page, hits.Count == 0 && total == 0 ? "noMatch" : null);
    }

    /// <summary>
    /// One lookup per dictionary, each painted as soon as it answers: a dictionary that is slow or held does not keep
    /// the others' results off the screen.
    /// </summary>
    public async Task<IReadOnlyList<SearchPage>> LookupEachAsync(string query, string? edition, uint limit,
        Action<SearchPage>? painted = null, RequestGeneration? generation = null, CancellationToken cancellation = default)
    {
        Task<SearchPage>[] tasks = Scope(edition).Select(async dictionary =>
        {
            SearchPage page = await LookupAsync(query, dictionary.Edition, 0, limit, null, generation, cancellation);
            painted?.Invoke(page);
            return page;
        }).ToArray();
        return await Task.WhenAll(tasks);
    }

    public async Task<IReadOnlyList<string>> SuggestAsync(string prefix, string? edition, uint limit,
        RequestGeneration? generation = null, CancellationToken cancellation = default)
    {
        IReadOnlyList<OpenDictionary> scope = Scope(edition);
        if (scope.Count == 0) return [];
        Reply reply = await client.CallAsync("suggest", new
        {
            prefix,
            dicts = scope.Select(item => item.Handle).ToArray(),
            limit,
        }, generation: generation, cancellation: cancellation);
        if (reply.Error is not null) return [];
        return reply.Ok!.Value.EnumerateArray().Select(item => item.GetString() ?? "").ToArray();
    }

    /// <summary>The typed error as one of the reader's five states; nothing is called a generic failure.</summary>
    public static string State(ServiceFailureException error) =>
        error.Error is { } detail ? State(detail, error.ErrorType) : ByType(error.ErrorType);

    public static string State(JsonElement error) => State(error, "");

    private static string State(JsonElement detail, string fallbackType)
    {
        // One mapping only: the typed state is read from the detail's own type, or the failure's.
        if (detail.ValueKind == JsonValueKind.Object && detail.TryGetProperty("type", out JsonElement type))
            return ByType(type.GetString() ?? fallbackType);
        return ByType(fallbackType);
    }

    private static string ByType(string type) => type switch
    {
        "needsImport" => OpenOutcome.NeedsImport,
        "unsupported" => OpenOutcome.Unsupported,
        "malformed" => OpenOutcome.Malformed,
        "notFound" or "io" => OpenOutcome.Missing,
        // A dictionary that is busy, timed out or speaking another contract is not a missing file: saying so would
        // tell the reader to look for a file that is right there.
        "deadline" or "busy" or "closed" or "cancelled" or "admission" or "staleHandle" or "incompatible" or
            "internal" or "tooLarge" or "editionMismatch" or "sourceChanged" or "contractMismatch" =>
            OpenOutcome.Unavailable,
        _ => OpenOutcome.Unavailable,
    };
}

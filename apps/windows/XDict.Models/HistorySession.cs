// The history's non-window model: the days the service returns, the drawer's language filter, removal and its undo,
// the gloss a card leads with (cached for the session, never stored), and the first-run disclosure that turns the
// recording path on. The drawer's form is Probe A's; this layer holds no window.
using XDict.Client;

namespace XDict.Models;

public sealed class HistorySession(
    ServiceClient client,
    Func<LearningSettings>? settings = null,
    Func<double>? now = null,
    Func<int>? utcOffset = null,
    Func<string>? device = null)
{
    private readonly Func<LearningSettings> settings = settings ?? (() => LearningSettings.Load());
    private readonly Func<double> now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    private readonly Func<int> utcOffset = utcOffset ?? (() => (int)DateTimeOffset.Now.Offset.TotalSeconds);
    private readonly Func<string> device = device ?? (() => DeviceIdentity.Current());
    private readonly System.Collections.Concurrent.ConcurrentDictionary<
        (string Edition, string Key, uint Occurrence), Task<HistoryGloss>> glosses = new();

    public History History { get; private set; } = new([]);
    public IReadOnlyList<HistoryCard> Cards => History.Cards;

    /// <summary>True until the first-run disclosure says the history is kept locally.</summary>
    public bool NeedsDisclosure => !settings().HistoryDisclosed;

    public async Task LoadAsync(CancellationToken cancellation = default)
    {
        History = StudyWire.Read<History>(
            await client.CallAsync("ledgerHistory", new { now = now(), utcOffsetSeconds = utcOffset() },
                cancellation: cancellation).ConfigureAwait(false));
    }

    /// <summary>The drawer's filter: an empty set shows every stored language; otherwise only those languages.</summary>
    public IReadOnlyList<HistoryCard> Visible(IReadOnlyList<string>? languages) =>
        languages is null || languages.Count == 0
            ? Cards
            : Cards.Where(card => languages.Contains(card.Reading.Language)).ToList();

    /// <summary>Hides the card's readings behind a tombstone that carries no content.</summary>
    public async Task<string> RemoveAsync(HistoryCard card, CancellationToken cancellation = default)
    {
        var removal = new { eventIds = card.Events, at = now(), device = device() };
        string outcome = StudyWire.Read<string>(
            await client.CallAsync("ledgerRemove", new
            {
                removal,
                operation = "remove:" + Guid.NewGuid().ToString("N"),
            }, cancellation: cancellation).ConfigureAwait(false));
        await LoadAsync(cancellation).ConfigureAwait(false);
        return outcome;
    }

    public async Task<string> RestoreAsync(HistoryCard card, CancellationToken cancellation = default)
    {
        var removal = new { eventIds = card.Events, at = now(), device = device() };
        string outcome = StudyWire.Read<string>(
            await client.CallAsync("ledgerRestore", new
            {
                removal,
                operation = "restore:" + Guid.NewGuid().ToString("N"),
            }, cancellation: cancellation).ConfigureAwait(false));
        await LoadAsync(cancellation).ConfigureAwait(false);
        return outcome;
    }

    /// <summary>The card's gloss, read from the recorded edition and cached for this session; a dictionary with no
    /// usable text answers no text, never an error.</summary>
    public Task<HistoryGloss> GlossAsync(HistoryCard card, CancellationToken cancellation = default)
    {
        var key = (card.Reading.Edition, card.Reading.EntryKey, card.Reading.Occurrence);
        // One read per card even when two cards ask at once, and one cache that concurrent callers can use; a failed
        // or cancelled read leaves no faulted entry behind to fail every later ask.
        return glosses.GetOrAdd(key, _ => ReadGlossAsync(key, card, cancellation));
    }

    private async Task<HistoryGloss> ReadGlossAsync((string Edition, string Key, uint Occurrence) key,
        HistoryCard card, CancellationToken cancellation)
    {
        try
        {
            return StudyWire.Read<HistoryGloss>(
                await client.CallAsync("entryGloss", new { entry = card.EntryRef }, cancellation: cancellation)
                    .ConfigureAwait(false));
        }
        catch
        {
            glosses.TryRemove(key, out _);
            throw;
        }
    }

    /// <summary>The reader read the disclosure: keep the history locally from now on, and write the choice.</summary>
    public LearningSettings Disclose()
    {
        LearningSettings next = settings() with { HistoryEnabled = true, HistoryDisclosed = true };
        next.Save();
        return next;
    }
}

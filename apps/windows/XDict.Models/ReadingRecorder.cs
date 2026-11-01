// **When a finished entry is a reading** (plan §2.2, D14): only an entry that actually drew, for the delivery that
// still owns the presentation, with a sentence captured. The no-results placeholder acknowledges `shown` but records
// nothing; neither does a superseded, failed or sentence-less lookup.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;

namespace XDict.Models;

/// <summary>The decision in one value, so each case that must record nothing is a test.</summary>
public static class HistoryCapture
{
    public static bool Records(bool onScreen, bool current, bool hasEntry, bool hasSentence, bool historyEnabled) =>
        onScreen && current && hasEntry && hasSentence && historyEnabled;
}

/// <summary>What the core's `ledgerRecord` answered, as the app reads it.</summary>
public enum LedgerRecordOutcome
{
    Recorded,
    Duplicate,
    Uncertain,
    SkippedLanguage,
    Ineligible,
}

/// <summary>One reading, as the history records it; the app computes no identity, grouping or filter — the core does.</summary>
public sealed class ReadingRecorder(ServiceClient client)
{
    /// <summary>The contract's reading, one for one: the word as read, the captured sentence and range, the edition and
    /// entry, the dictionary's name and declared language, the moment, the device. A dictionary missing from the
    /// library leaves its name and language empty, which the core keeps as unknown.</summary>
    public static object Reading(CapturedTerm term, SearchHit hit, LibraryDictionary? dictionary, double at, string device)
    {
        if (term.Context is not CaptureContext.Available context)
            throw new InvalidOperationException("a reading needs a captured sentence");
        JsonElement entry = hit.Entry;
        string key = entry.TryGetProperty("key", out JsonElement named) ? named.GetString() ?? term.Term : term.Term;
        uint occurrence = entry.TryGetProperty("occurrence", out JsonElement n) && n.TryGetUInt32(out uint number)
            ? number
            : 0;
        object? span = context.Start >= 0 && context.Length > 0
            ? new { start = (uint)context.Start, len = (uint)context.Length }
            : null;
        return new
        {
            surface = term.Term,
            lemma = key,
            sentence = context.Sentence,
            span,
            cut = (byte)0,
            quality = "complete",
            edition = hit.Edition,
            entryKey = key,
            occurrence,
            dictionaryName = dictionary?.DisplayName ?? "",
            language = dictionary?.SearchLanguage ?? "",
            at,
            device,
        };
    }

    /// <summary>Records one reading where the switch is on and a sentence was captured; null where nothing should be
    /// written. A stale service answer is retried once with the same operation id, so a lost acknowledgement is one
    /// event, never two.</summary>
    public async Task<LedgerRecordOutcome?> RecordAsync(CapturedTerm term, SearchHit hit, LibraryDictionary? dictionary,
        LearningSettings settings, string? devicePath = null, CancellationToken cancellation = default)
    {
        if (!settings.HistoryEnabled) return null;
        if (term.Context is not CaptureContext.Available) return null;
        double at = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        object reading = Reading(term, hit, dictionary, at, DeviceIdentity.Current(devicePath));
        string operation = "reading:" + Guid.NewGuid().ToString("N");
        var body = new { reading, operation, targetLanguages = settings.Targets.ToArray() };
        Reply reply = await client.CallAsync("ledgerRecord", body, cancellation: cancellation).ConfigureAwait(false);
        if (reply.Error is { } error)
        {
            string? type = error.TryGetProperty("type", out JsonElement kind) ? kind.GetString() : null;
            if (type is "staleHandle" or "deadline" or "closed")
                reply = await client.CallAsync("ledgerRecord", body, cancellation: cancellation).ConfigureAwait(false);
        }
        if (reply.Ok is { ValueKind: JsonValueKind.String } ok && ok.GetString() is { } outcome &&
            Enum.TryParse(outcome, ignoreCase: true, out LedgerRecordOutcome parsed))
            return parsed;
        return null;
    }
}

/// <summary>**Which device recorded a reading** (ADR-0025): minted once and kept in the app's state; evidence on the
/// card, never identity.</summary>
public static class DeviceIdentity
{
    public static string Path =>
        Environment.GetEnvironmentVariable("XDICT_DEVICE")
        ?? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "XDict", "device");

    public static string Current(string? path = null)
    {
        path ??= Path;
        try
        {
            if (File.Exists(path))
            {
                string known = File.ReadAllText(path).Trim();
                if (known.Length > 0) return known;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        string minted = Guid.NewGuid().ToString("N");
        try
        {
            string? folder = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path));
            if (folder is not null) Directory.CreateDirectory(folder);
            File.WriteAllText(path, minted);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return minted;
    }
}

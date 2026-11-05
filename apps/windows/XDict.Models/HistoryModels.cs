// The reading history as contract 2 carries it: the days the drawer shows, each card's reading and events, the
// removal tombstone, and the entry gloss a card leads with (ADR-0023, ADR-0037). The core groups, collapses and
// labels; this layer parses the shapes and maps the card's own facts.
using System.Text.Json.Serialization;
using XDict.Contract;

namespace XDict.Models;

/// <summary>A range of the sentence, in UTF-16 code units — the capture contract's unit.</summary>
public sealed record HistorySpan(uint Start, uint Len);

/// <summary>One reading: the word, the sentence and its span, the capture's doubts, the edition and entry, the moment.</summary>
public sealed record HistoryReading(
    string Surface,
    string Lemma,
    string Sentence,
    HistorySpan? Span,
    ushort Cut,
    string Quality,
    string Edition,
    string EntryKey,
    uint Occurrence,
    string DictionaryName,
    string Language,
    double At,
    string Device);

/// <summary>One card: a reading, how often it was met that day, and the reading events it is made of.</summary>
public sealed record HistoryCard(HistoryReading Reading, uint Times, IReadOnlyList<string> Events)
{
    [JsonIgnore]
    public object EntryRef => new { edition = Reading.Edition, key = Reading.EntryKey, occurrence = Reading.Occurrence };
}

/// <summary>One calendar day of readings, newest card first, in the reader's own zone.</summary>
public sealed record HistoryDay(string Id, double Start, string Label, IReadOnlyList<HistoryCard> Cards);

public sealed record History(IReadOnlyList<HistoryDay> Days)
{
    [JsonIgnore]
    public IReadOnlyList<HistoryCard> Cards => Days.SelectMany(day => day.Cards).ToList();
}

/// <summary>A removal, or the same tombstone applied in reverse: the cards' event ids and a stamp, never content.</summary>
public sealed record HistoryRemoval(IReadOnlyList<string> EventIds, double At, string Device);

/// <summary>An entry reference in the history's own terms.</summary>
public sealed record HistoryEntryRef(string Edition, string Key, uint Occurrence);

/// <summary>An entry's brief gloss for a card: the first sense's definition or translation; no text is data.</summary>
public sealed record HistoryGloss(
    HistoryEntryRef Entry,
    string? Text,
    string? Pos,
    string? Source,
    bool Truncated);

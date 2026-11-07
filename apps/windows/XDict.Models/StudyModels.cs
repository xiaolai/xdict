// The study records as the service carries them (contract 2): a target, a card, a note, a grade's outcome, a
// conflict and a re-anchor report. The shell computes no identity, due date or ordering; this layer only parses the
// core's shapes and derives the key the review calls name (the macOS contract's StudyTarget.key).
using System.Text.Json;
using System.Text.Json.Serialization;
using XDict.Client;
using XDict.Contract;

namespace XDict.Models;

/// <summary>The reader's answer to a card; the wire spells it as the core's enum does.</summary>
public enum StudyGrade
{
    Again,
    Hard,
    Good,
    Easy,
}

public static class StudyGradeNames
{
    public static string Wire(this StudyGrade grade) => grade switch
    {
        StudyGrade.Again => "again",
        StudyGrade.Hard => "hard",
        StudyGrade.Good => "good",
        StudyGrade.Easy => "easy",
        _ => throw new ArgumentOutOfRangeException(nameof(grade), grade, "an undefined grade has no wire name"),
    };
}

/// <summary>What a study target is; v1 has entry-level targets only.</summary>
public sealed record StudyTarget(
    string Lineage,
    string EntryKey,
    uint Occurrence,
    string Kind,
    string Edition,
    string DefinitionHash)
{
    /// <summary>The identity the review calls name: everything but the evidence.</summary>
    [JsonIgnore]
    public string Key => $"{Lineage}\u001f{EntryKey}\u001f{Occurrence}\u001f{Kind}";

    /// <summary>The entry reference the note and definition calls carry.</summary>
    [JsonIgnore]
    public object EntryRef => new { edition = Edition, key = EntryKey, occurrence = Occurrence };
}

/// <summary>A card's state as the scheduler left it.</summary>
public sealed record StudyCardState(
    double? Stability,
    double? Difficulty,
    string Phase,
    double? LastReview,
    double? Due);

/// <summary>The reader's own words about an entry; no dictionary content.</summary>
public sealed record StudyNote(StudyTarget Target, string Text, double At, string Device);

/// <summary>One card the review queue shows: its target, note, state and the head a grade extends.</summary>
public sealed record StudyCard(
    StudyTarget Target,
    StudyNote Note,
    StudyCardState State,
    string Head,
    string NoteHead,
    ulong Grades)
{
    [JsonIgnore]
    public bool IsNew => string.Equals(State.Phase, "new", StringComparison.Ordinal);
}

public sealed record ReviewSummary(ulong Due, double? NextDue);

/// <summary>What a grade or an undo did, and the card as it now stands.</summary>
public sealed record ReviewOutcome(string Outcome, StudyCard Card)
{
    [JsonIgnore]
    public bool Written => Outcome is "recorded" or "duplicate";

    [JsonIgnore]
    public bool Ineligible => Outcome == "ineligible";
}

public sealed record ConflictCandidate(string Id, string Grade, double At, string Device, StudyCardState After);

public sealed record CardConflict(StudyTarget Target, StudyNote Note, IReadOnlyList<ConflictCandidate> Candidates);

public sealed record ReanchorOutcome(StudyTarget Target, string Result);

public sealed record ReanchorReport(IReadOnlyList<ReanchorOutcome> Outcomes);

public sealed record EraseReport(ulong ClearedReadings, ulong ClearedNotes, ulong ClearedGrades, string Recoverable);

/// <summary>The scheduling settings a grade is made under (the core's ReviewPolicy).</summary>
public sealed record ReviewPolicy(double Retention, int MaximumDays);

/// <summary>The wire's record parsing, in one place: every study reply carries the core's camelCase shape.</summary>
public static class StudyWire
{
    public static T Read<T>(Reply reply) where T : class
    {
        if (reply.Error is { } error)
            throw new ServiceFailureException(error.TryGetProperty("type", out JsonElement kind)
                ? kind.GetString() ?? "internal"
                : "internal", error);
        if (reply.Ok is not { } ok) throw new InvalidOperationException("the study reply has no answer");
        T value = ok.Deserialize<T>(Wire.Options) ?? throw new InvalidOperationException("the study reply did not decode");
        return Valid(value);
    }

    public static T? ReadOrNull<T>(Reply reply) where T : class
    {
        if (reply.Error is { } error)
            throw new ServiceFailureException(error.TryGetProperty("type", out JsonElement kind)
                ? kind.GetString() ?? "internal"
                : "internal", error);
        return reply.Ok is { } ok ? ok.Deserialize<T>(Wire.Options) is { } value ? Valid(value) : null : null;
    }

    /// <summary>A record is published only when its mandatory members are there. Deserialization alone accepts `{}`
    /// as any record — a History with no days, a StudyCard with no target — and every consumer below would then
    /// fail somewhere else. The contract's records are all-mandatory, so a missing one is a protocol violation.</summary>
    private static T Valid<T>(T value) where T : class
    {
        if (!Complete(value))
            throw new ContractViolationException(
                $"a {typeof(T).Name} record is missing a member the contract requires");
        return value;
    }

    private static bool Complete(object? value) => value switch
    {
        null => false,
        History history => history.Days is not null && history.Days.All(Complete),
        HistoryDay day => day.Id is not null && day.Label is not null && day.Cards is not null &&
            day.Cards.All(Complete),
        HistoryCard card => card.Reading is not null && card.Events is not null &&
            card.Events.All(id => id is not null) && Complete(card.Reading),
        HistoryReading reading => reading.Surface is not null && reading.Lemma is not null &&
            reading.Sentence is not null && reading.Quality is not null && reading.Edition is not null &&
            reading.EntryKey is not null && reading.DictionaryName is not null && reading.Language is not null &&
            reading.Device is not null,
        HistoryGloss gloss => gloss.Entry is not null && gloss.Entry.Edition is not null &&
            gloss.Entry.Key is not null,
        StudyCard card => card.Target is not null && card.Note is not null && card.State is not null &&
            card.Head is not null && card.NoteHead is not null && Complete(card.Target) && Complete(card.Note) &&
            Complete(card.State),
        StudyTarget target => target.Lineage is not null && target.EntryKey is not null && target.Kind is not null &&
            target.Edition is not null && target.DefinitionHash is not null,
        StudyNote note => note.Target is not null && note.Text is not null && note.Device is not null &&
            Complete(note.Target),
        StudyCardState state => state.Phase is not null,
        ReviewOutcome outcome => outcome.Outcome is not null && outcome.Card is not null && Complete(outcome.Card),
        CardConflict conflict => conflict.Target is not null && conflict.Note is not null &&
            conflict.Candidates is not null && conflict.Candidates.All(candidate => candidate is not null &&
                candidate.Id is not null && candidate.Grade is not null && candidate.Device is not null &&
                candidate.After is not null && Complete(candidate.After)),
        ReanchorReport report => report.Outcomes is not null && report.Outcomes.All(outcome => outcome is not null &&
            outcome.Target is not null && outcome.Result is not null && Complete(outcome.Target)),
        EraseReport report => report.Recoverable is not null,
        _ => true,
    };
}

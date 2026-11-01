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
        _ => "easy",
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
        return ok.Deserialize<T>(Wire.Options) ?? throw new InvalidOperationException("the study reply did not decode");
    }

    public static T? ReadOrNull<T>(Reply reply) where T : class
    {
        if (reply.Error is { } error)
            throw new ServiceFailureException(error.TryGetProperty("type", out JsonElement kind)
                ? kind.GetString() ?? "internal"
                : "internal", error);
        return reply.Ok is { } ok ? ok.Deserialize<T>(Wire.Options) : null;
    }
}

// The review's non-window model: the queue and summary the service returns, reveal-before-grade, one grade or undo
// per card, the conflict resolution and the re-anchor path. The window maps keys and draws; every rule lives here.
using XDict.Client;

namespace XDict.Models;

public sealed class ReviewSession(
    ServiceClient client,
    Func<LearningSettings>? settings = null,
    Func<double>? now = null,
    Func<string>? device = null,
    Func<string, bool>? editionAvailable = null)
{
    private readonly Func<LearningSettings> settings = settings ?? (() => LearningSettings.Load());
    private readonly Func<double> now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    private readonly Func<string> device = device ?? (() => DeviceIdentity.Current());

    public IReadOnlyList<StudyCard> Cards { get; private set; } = [];
    public ReviewSummary Summary { get; private set; } = new(0, null);
    public StudyCard? Current => Cards.Count > 0 ? Cards[0] : null;
    public bool Revealed { get; private set; }

    /// <summary>The grade event the Undo action voids; kept until a new grade or an undo.</summary>
    public string? LastGradeEvent { get; private set; }
    public string? LastGradeTarget { get; private set; }

    /// <summary>The card the next grade extends; the queue's first, or none when nothing is due.</summary>
    public bool CanGrade => Current is not null && Revealed;

    /// <summary>Whether the card's dictionary is open here; an unavailable card is shown, never opened as another.</summary>
    public bool CanOpen(StudyCard card) => editionAvailable?.Invoke(card.Target.Edition) ?? true;

    public async Task LoadAsync(uint limit = 20, CancellationToken cancellation = default)
    {
        double at = now();
        IReadOnlyList<StudyCard> cards = StudyWire.Read<List<StudyCard>>(
            await client.CallAsync("reviewQueue", new { now = at, limit }, cancellation: cancellation)
                .ConfigureAwait(false));
        Summary = StudyWire.Read<ReviewSummary>(
            await client.CallAsync("reviewSummary", new { now = at }, cancellation: cancellation)
                .ConfigureAwait(false));
        Cards = cards;
        Revealed = false;
    }

    /// <summary>Shows the card's answer; nothing may be graded before this call (the plan's reveal-before-grade).</summary>
    public bool Reveal()
    {
        if (Current is null) return false;
        Revealed = true;
        return true;
    }

    public async Task<ReviewOutcome> GradeAsync(StudyGrade grade, CancellationToken cancellation = default)
    {
        StudyCard card = Current ?? throw new InvalidOperationException("no card is due");
        if (!Revealed) throw new InvalidOperationException("the card must be revealed before it is graded");
        string target = card.Target.Key;
        var body = new
        {
            target,
            revision = card.Head,
            grade = grade.Wire(),
            policy = settings().Policy,
            stamp = Stamp(),
            operation = "grade:" + Guid.NewGuid().ToString("N"),
        };
        ReviewOutcome outcome = StudyWire.Read<ReviewOutcome>(
            await client.CallAsync("reviewGrade", body, cancellation: cancellation).ConfigureAwait(false));
        if (outcome.Written)
        {
            LastGradeEvent = outcome.Card.Head;
            LastGradeTarget = target;
        }
        await LoadAsync(cancellation: cancellation).ConfigureAwait(false);
        return outcome;
    }

    /// <summary>Voids the grade just made, while the card is still in the state it produced.</summary>
    public async Task<ReviewOutcome> UndoAsync(CancellationToken cancellation = default)
    {
        if (LastGradeEvent is not { } gradeEvent || LastGradeTarget is not { } target)
            throw new InvalidOperationException("there is no grade to undo");
        ReviewOutcome outcome = StudyWire.Read<ReviewOutcome>(
            await client.CallAsync("reviewUndo", new
            {
                target,
                gradeEvent,
                stamp = Stamp(),
                operation = "undo:" + Guid.NewGuid().ToString("N"),
            }, cancellation: cancellation).ConfigureAwait(false));
        LastGradeEvent = null;
        LastGradeTarget = null;
        await LoadAsync(cancellation: cancellation).ConfigureAwait(false);
        return outcome;
    }

    public async Task<IReadOnlyList<CardConflict>> ConflictsAsync(CancellationToken cancellation = default) =>
        StudyWire.Read<List<CardConflict>>(
            await client.CallAsync("studyConflicts", null, cancellation: cancellation).ConfigureAwait(false));

    /// <summary>Keeps one branch of a conflict; the others are voided with what descended from them.</summary>
    public async Task<ReviewOutcome> ResolveAsync(CardConflict conflict, ConflictCandidate keep,
        CancellationToken cancellation = default)
    {
        ReviewOutcome outcome = StudyWire.Read<ReviewOutcome>(
            await client.CallAsync("reviewResolve", new
            {
                target = conflict.Target.Key,
                keep = keep.Id,
                stamp = Stamp(),
                operation = "resolve:" + Guid.NewGuid().ToString("N"),
            }, cancellation: cancellation).ConfigureAwait(false));
        await LoadAsync(cancellation: cancellation).ConfigureAwait(false);
        return outcome;
    }

    public async Task<ReviewSummary> SummaryAsync(CancellationToken cancellation = default) =>
        StudyWire.Read<ReviewSummary>(
            await client.CallAsync("reviewSummary", new { now = now() }, cancellation: cancellation)
                .ConfigureAwait(false));

    /// <summary>Moves the notes of one edition to another under the same lineage; every result is the core's.</summary>
    public async Task<ReanchorReport> ReanchorAsync(string oldEdition, string newEdition,
        CancellationToken cancellation = default) =>
        StudyWire.Read<ReanchorReport>(
            await client.CallAsync("studyReanchor", new
            {
                oldEdition,
                newEdition,
                stamp = Stamp(),
                operationPrefix = "reanchor:" + Guid.NewGuid().ToString("N"),
            }, cancellation: cancellation).ConfigureAwait(false));

    private object Stamp() => new { at = now(), device = device() };
}

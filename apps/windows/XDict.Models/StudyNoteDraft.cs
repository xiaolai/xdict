// The note editor's model: the reader's words for one card, dirt tracked so closing can ask, the save through the
// edition-named operation, and the definition hash the note keeps as evidence instead of the definition's text.
using XDict.Client;

namespace XDict.Models;

public sealed class StudyNoteDraft(StudyCard card, StudyNote? existing = null)
{
    private string original = existing?.Text ?? card.Note.Text;

    public string Text { get; private set; } = existing?.Text ?? card.Note.Text;
    public StudyTarget Target => card.Target;
    public bool IsDirty => !string.Equals(Text, original, StringComparison.Ordinal);

    public void Edit(string text) => Text = text;

    public void Revert() => Text = original;

    /// <summary>Null when there is nothing to save; otherwise the note the core wrote (or its duplicate).</summary>
    public async Task<StudyNote?> SaveAsync(ServiceClient client, string dictionaryName, string? dict = null,
        Func<double>? now = null, Func<string>? device = null, CancellationToken cancellation = default)
    {
        if (!IsDirty) return existing;
        var body = new
        {
            entry = Target.EntryRef,
            text = Text,
            name = dictionaryName,
            stamp = new
            {
                at = (now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeSeconds()))(),
                device = (device ?? (() => DeviceIdentity.Current()))(),
            },
            operation = "note:" + Guid.NewGuid().ToString("N"),
        };
        StudyNote note = StudyWire.Read<StudyNote>(
            await client.CallAsync("studyNoteAt", body, cancellation: cancellation).ConfigureAwait(false));
        original = note.Text;
        Text = note.Text;
        return note;
    }

    /// <summary>The definition's hash for this card, when the dictionary's handle is open; the save records the same
    /// evidence itself, so a missing handle only hides the preview.</summary>
    public async Task<string?> EvidenceAsync(ServiceClient client, string? dict,
        CancellationToken cancellation = default)
    {
        if (string.IsNullOrWhiteSpace(dict)) return null;
        return StudyWire.Read<string>(
            await client.CallAsync("definitionHash", new { dict, entry = Target.EntryRef },
                cancellation: cancellation).ConfigureAwait(false));
    }
}

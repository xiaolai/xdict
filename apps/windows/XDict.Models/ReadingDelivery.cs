// **The terminal act of one capture presentation** (plan §2.2, D14): the acknowledgement first, and the reading a
// drawn entry leaves only when that acknowledgement is the delivery's own. The book refuses an ending for a
// superseded, cancelled or already-ended delivery, and a refused ending means the delivery no longer owns the panel:
// nothing about it may be recorded. A failed render and the no-results placeholder acknowledge `shown` and record
// nothing, and so does a sentence-less capture or the reader's own switch.
using XDict.Client;

namespace XDict.Models;

/// <summary>Ends one presentation: the acknowledgement, then — only when it landed and an entry drew — one reading.</summary>
public sealed class ReadingDelivery(ReadingRecorder recorder)
{
    /// <summary>The acknowledgement the book kept (null when it refused the ending), and the record started (null when
    /// nothing may be written). Awaiting <see cref="Recording"/> completes the write; its own refusals are logged, never
    /// thrown back into the capture — the entry drew, and a lost history record must not fail the capture.</summary>
    public sealed record Outcome(CaptureAcknowledgement? Acknowledged, Task? Recording);

    public Outcome Complete(CaptureDelivery delivery, CaptureRequests book, SearchHit? drawn, LibraryDictionary? dictionary,
        LearningSettings settings, string? devicePath = null)
    {
        if (!book.Acknowledge(delivery.Request, delivery.Generation, CaptureOutcome.Shown))
            return new Outcome(null, null);
        var acknowledged = new CaptureAcknowledgement(delivery.Request.Number, delivery.Generation, CaptureOutcome.Shown);
        if (drawn is null) return new Outcome(acknowledged, null);
        if (!HistoryCapture.Records(onScreen: true, current: true, hasEntry: true,
                hasSentence: delivery.Term.Context is CaptureContext.Available, settings.HistoryEnabled))
            return new Outcome(acknowledged, null);
        // The book says this delivery owned the panel; a drawn entry and the reader's switch say a reading happened.
        return new Outcome(acknowledged, Task.Run(() => RecordAsync(delivery, drawn, dictionary, settings, devicePath)));
    }

    private async Task RecordAsync(CaptureDelivery delivery, SearchHit drawn, LibraryDictionary? dictionary,
        LearningSettings settings, string? devicePath)
    {
        try
        {
            await recorder.RecordAsync(delivery.Term, drawn, dictionary, settings, devicePath).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            // Observable, and its message names a type, never the sentence.
            System.Diagnostics.Debug.WriteLine(
                "the reading was not recorded: " + error.GetType().Name + ": " + error.Message);
        }
    }
}

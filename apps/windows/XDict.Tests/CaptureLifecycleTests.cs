// The capture contract's four lifecycle rules as native tests (conformance/capture/lifecycle.md; CONTRACT.md §5).
using System.Text.Json.Nodes;
using XDict.Models;
using Xunit;

public class CaptureLifecycleTests
{
    private sealed class RecordingSink(bool refusing = false) : ICaptureSink
    {
        public List<CaptureDelivery> Delivered { get; } = [];

        public CaptureDeliveryAnswer Deliver(CaptureDelivery delivery)
        {
            Delivered.Add(delivery);
            return refusing ? CaptureDeliveryAnswer.Refused : CaptureDeliveryAnswer.Accepted;
        }
    }

    private static CapturedTerm Make(string term = "harbour", string? sentence = null)
    {
        sentence ??= $"Please {term} the door.";
        var context = new JsonObject
        {
            ["kind"] = "available",
            ["sentence"] = sentence,
            ["term"] = new JsonObject { ["start"] = sentence.IndexOf(term, StringComparison.Ordinal), ["length"] = term.Length },
            ["cut"] = new JsonArray(),
            ["gap"] = null,
        };
        var input = new JsonObject
        {
            ["term"] = term, ["trigger"] = "selection", ["acquisition"] = "textRange", ["confidence"] = 1,
            ["source"] = null, ["pointer"] = null,
            ["box"] = new JsonObject { ["kind"] = "absent" }, ["context"] = context,
        };
        CaptureValue.Result result = CaptureValue.Make(input);
        Assert.True(result.Valid, $"the test's own term was refused: {result.Code}");
        return CapturedTerm.From(result)!;
    }

    /// Rule 1 — the number exists before the read, strictly in the order asked, and claiming is a second act.
    [Fact]
    public void NumbersExistBeforeTheReadAndClaimingIsASecondAct()
    {
        var book = new CaptureRequests();
        CaptureRequest one = book.Begin(CaptureTrigger.Selection);
        CaptureRequest two = book.Begin(CaptureTrigger.Service);
        CaptureRequest three = book.Begin(CaptureTrigger.Menu);
        Assert.Equal([1, 2, 3], new[] { one.Number, two.Number, three.Number });
        Assert.Null(book.Terminal(one)); // a number alone presents nothing

        // A hover numbered before a later shortcut holds its number; the shortcut claims presentation.
        CaptureRequest hover = book.Begin(CaptureTrigger.PointerGesture);
        CaptureRequest shortcut = book.BeginPresenting(CaptureTrigger.Selection);
        Assert.True(shortcut.Number > hover.Number);
        Assert.True(book.IsCurrent(shortcut));
        Assert.False(book.IsCurrent(hover));
        Assert.Equal(CaptureDeliveryAnswer.Refused, book.Present(Make(), hover, new RecordingSink()));
        Assert.Equal(CaptureOutcome.Cancelled, book.Terminal(hover)?.Outcome);

        // A hover numbered after the shortcut claims presentation normally.
        CaptureRequest later = book.Begin(CaptureTrigger.PointerGesture);
        var sink = new RecordingSink();
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Present(Make(), later, sink));
        Assert.True(book.IsCurrent(later));
        Assert.Single(sink.Delivered);
    }

    /// Rule 2 — every request ends, exactly once, in each of the six ways the contract names; the book stays bounded.
    [Fact]
    public void EveryRequestEndsExactlyOnce()
    {
        var book = new CaptureRequests();
        var told = new List<CaptureAcknowledgement>();
        book.OnEnd(told.Add);
        var sink = new RecordingSink();

        // shown
        CaptureRequest shown = book.BeginPresenting(CaptureTrigger.Selection);
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(Make(), shown, sink));
        int shownGeneration = sink.Delivered[^1].Generation;
        Assert.True(book.Acknowledge(shown, shownGeneration, CaptureOutcome.Shown));
        Assert.False(book.Acknowledge(shown, shownGeneration, CaptureOutcome.NotShown)); // duplicate changes nothing
        Assert.Equal(CaptureOutcome.Shown, book.Terminal(shown)?.Outcome);

        // notShown
        CaptureRequest notShown = book.BeginPresenting(CaptureTrigger.Menu);
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(Make(), notShown, sink));
        Assert.True(book.Acknowledge(notShown, sink.Delivered[^1].Generation, CaptureOutcome.NotShown));
        Assert.Equal(CaptureOutcome.NotShown, book.Terminal(notShown)?.Outcome);

        // refused before delivery: cancelled with generation 0
        CaptureRequest refused = book.Begin(CaptureTrigger.PointerGesture);
        Assert.True(book.Cancel(refused));
        Assert.False(book.Cancel(refused));
        Assert.Equal(new CaptureAcknowledgement(refused.Number, 0, CaptureOutcome.Cancelled), book.Terminal(refused));

        // superseded by a newer request that claimed presentation
        CaptureRequest superseded = book.Begin(CaptureTrigger.PointerGesture);
        book.BeginPresenting(CaptureTrigger.Selection);
        Assert.Equal(CaptureOutcome.Cancelled, book.Terminal(superseded)?.Outcome);

        // open when the presentation closed
        CaptureRequest open = book.BeginPresenting(CaptureTrigger.Service);
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(Make(), open, sink));
        int openGeneration = sink.Delivered[^1].Generation;
        book.Close();
        Assert.Equal(new CaptureAcknowledgement(open.Number, openGeneration, CaptureOutcome.Cancelled), book.Terminal(open));

        // delivered and its consumer went away
        CaptureRequest gone = book.BeginPresenting(CaptureTrigger.Selection);
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(Make(), gone, sink));
        int goneGeneration = sink.Delivered[^1].Generation;
        book.ConsumerGone();
        Assert.Equal(new CaptureAcknowledgement(gone.Number, goneGeneration, CaptureOutcome.Cancelled), book.Terminal(gone));

        Assert.Equal(told.Count, told.Select(ack => ack.Request).Distinct().Count()); // one ending each

        for (int i = 0; i < 5_000; i++) Assert.True(book.Cancel(book.Begin(CaptureTrigger.PointerGesture)));
        Assert.True(book.Retained.Ended <= 64, $"the book kept {book.Retained.Ended} ended numbers");
        Assert.Equal(0, book.Retained.Open);
    }

    /// Rule 3 — a stale answer, a stale document and an identical word all change nothing.
    [Fact]
    public void AStaleAnswerChangesNothing()
    {
        var book = new CaptureRequests();
        var sink = new RecordingSink();

        // A stale generation leaves the request open; the latest delivery's own answer ends it.
        CaptureRequest request = book.Begin(CaptureTrigger.PointerGesture);
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(Make(), request, sink));
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(Make("held"), request, sink));
        int stale = sink.Delivered[0].Generation, latest = sink.Delivered[1].Generation;
        Assert.NotEqual(stale, latest);
        Assert.False(book.Acknowledge(request, stale, CaptureOutcome.Shown));
        Assert.Null(book.Terminal(request));
        Assert.True(book.Acknowledge(request, latest, CaptureOutcome.NotShown));
        Assert.Equal(CaptureOutcome.NotShown, book.Terminal(request)?.Outcome);

        // A stale document at the consumer acknowledges nothing, even when the word is the same.
        CaptureRequest a = book.BeginPresenting(CaptureTrigger.Selection);
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(Make("tide"), a, sink));
        int aGeneration = sink.Delivered[^1].Generation;
        CaptureRequest b = book.BeginPresenting(CaptureTrigger.Selection);
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(Make("tide"), b, sink));
        int bGeneration = sink.Delivered[^1].Generation;
        var presented = new PresentedEntry();
        presented.Show(b, bGeneration);
        // A's document finishes while B's term is on screen: it acknowledges nothing — not B, and not A, which the book
        // already ended cancelled when B claimed presentation.
        Assert.False(presented.Finish(a, aGeneration));
        Assert.Null(book.Terminal(b));
        Assert.False(book.Acknowledge(a, aGeneration, CaptureOutcome.Shown));
        Assert.Equal(CaptureOutcome.Cancelled, book.Terminal(a)?.Outcome);
        // B's own document is the one the presentation asked to show: its finish acknowledges B under B's generation.
        Assert.True(presented.Finish(b, bGeneration));
        Assert.True(book.Acknowledge(b, bGeneration, CaptureOutcome.Shown));
        Assert.Equal(CaptureOutcome.Shown, book.Terminal(b)?.Outcome);

        // Two requests for the same word settle apart.
        CaptureRequest first = book.Begin(CaptureTrigger.PointerGesture);
        CaptureRequest second = book.Begin(CaptureTrigger.PointerGesture);
        Assert.NotEqual(CaptureDeliveryAnswer.Refused, book.Deliver(Make("tide"), first, sink));
        Assert.NotEqual(CaptureDeliveryAnswer.Refused, book.Deliver(Make("tide"), second, sink));
        Assert.True(book.Acknowledge(second, sink.Delivered[^1].Generation, CaptureOutcome.NotShown));
        Assert.True(book.Acknowledge(first, sink.Delivered[^2].Generation, CaptureOutcome.Shown));
        Assert.Equal(CaptureOutcome.Shown, book.Terminal(first)?.Outcome);
        Assert.Equal(CaptureOutcome.NotShown, book.Terminal(second)?.Outcome);
    }

    /// Rule 4 on Windows — no Services exist (the mapping says so), but a reading suspended mid-flight is cancelled by
    /// the shortcut and by Escape, presents nothing, changes nothing, and its request still ends exactly once.
    [Fact]
    public async Task AnInFlightReadIsCancelledByTheShortcutAndByEscape()
    {
        foreach (bool escape in new[] { false, true })
        {
            var book = new CaptureRequests();
            var sink = new RecordingSink();
            var endings = new List<CaptureAcknowledgement>();
            using var read = new CancellationTokenSource();
            book.OnEnd(ending =>
            {
                endings.Add(ending);
                if (ending.Request == 1) read.Cancel();
            });
            CaptureRequest service = book.BeginPresenting(CaptureTrigger.Service);
            Assert.Equal(1, service.Number);
            Task<CapturedTerm?> suspended = Task.Delay(Timeout.Infinite, read.Token)
                .ContinueWith(_ => (CapturedTerm?)null, TaskScheduler.Default);

            if (escape) Assert.True(book.Cancel(service));
            else book.BeginPresenting(CaptureTrigger.Selection); // the shortcut
            Assert.True(read.IsCancellationRequested, escape ? "Escape left the read running" : "the shortcut left the read running");

            // Whatever the read answers afterwards presents nothing.
            CaptureDeliveryAnswer late = book.Present(Make(), service, sink);
            Assert.Equal(CaptureDeliveryAnswer.Refused, late);
            Assert.Empty(sink.Delivered);
            Assert.Equal(CaptureOutcome.Cancelled, book.Terminal(service)?.Outcome);
            Assert.Single(endings, ending => ending.Request == service.Number);
            await Task.WhenAny(suspended, Task.Delay(TimeSpan.FromSeconds(5)));
            Assert.Equal(CaptureOutcome.Cancelled, book.Terminal(service)?.Outcome); // still one ending, unchanged
        }
    }
}

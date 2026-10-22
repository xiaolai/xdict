// The sentence reaches no consumer (CONTRACT.md §6; lifecycle.md): a canary travels through delivery, settlement,
// cancellation, replacement, closing and refusal; every string a consumer or a log line could hold is scanned.
using System.Text.Json.Nodes;
using XDict.Models;
using Xunit;

public class CapturePrivacyCanaryTests
{
    private const string Marker = "CANARY-9f3c";
    private const string Sentence = Marker + " the hollow moon drifted over the harbour while nobody watched.";
    private const string Term = "harbour";

    private sealed class Consumer(bool refusing = false) : ICaptureSink
    {
        public List<string> Recorded { get; } = [];
        public List<CaptureDelivery> Delivered { get; } = [];

        public CaptureDeliveryAnswer Deliver(CaptureDelivery delivery)
        {
            Delivered.Add(delivery);
            Recorded.AddRange([delivery.Term.Term, delivery.Term.ToString(), delivery.ToString(),
                delivery.Request.ToString(), delivery.Generation.ToString()]);
            return refusing ? CaptureDeliveryAnswer.Refused : CaptureDeliveryAnswer.Accepted;
        }
    }

    private static CapturedTerm Term_(CaptureContext? context = null)
    {
        JsonObject outcome = context switch
        {
            CaptureContext.Pending pending => new JsonObject { ["kind"] = "pending", ["handle"] = pending.Handle },
            CaptureContext.Unavailable unavailable => new JsonObject { ["kind"] = "unavailable", ["reason"] = unavailable.Reason },
            _ => new JsonObject
            {
                ["kind"] = "available",
                ["sentence"] = Sentence,
                ["term"] = new JsonObject { ["start"] = Sentence.IndexOf(Term, StringComparison.Ordinal), ["length"] = Term.Length },
                ["cut"] = new JsonArray(),
                ["gap"] = null,
            },
        };
        var input = new JsonObject
        {
            ["term"] = Term, ["trigger"] = "selection", ["acquisition"] = "textRange", ["confidence"] = 1,
            ["source"] = null, ["pointer"] = null,
            ["box"] = new JsonObject { ["kind"] = "absent" }, ["context"] = outcome,
        };
        CaptureValue.Result result = CaptureValue.Make(input);
        Assert.True(result.Valid, $"the canary term was refused: {result.Code}");
        return CapturedTerm.From(result)!;
    }

    [Fact]
    public async Task TheSentenceNeverLeavesTheSession()
    {
        var book = new CaptureRequests();
        var pending = new PendingContexts();
        var session = new CaptureContextSession(pending);
        var consumer = new Consumer();
        var endings = new List<string>();
        book.OnEnd(ack => endings.AddRange([ack.ToString(), ack.Outcome.ToString()]));

        // 1 — A delivery: the term goes to the consumer, the sentence only to the session.
        CapturedTerm first = Term_();
        CaptureRequest one = book.Begin(CaptureTrigger.Selection);
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(first, one, consumer));
        int generation = consumer.Delivered[^1].Generation;
        session.Hold(first, one.Number, generation);
        var inspected = new List<string> { first.ToString(), first.Context.ToString(), session.ToString(), one.ToString() };
        inspected.AddRange(consumer.Recorded);
        inspected.AddRange(endings);

        CaptureContext? held = session.Context(one.Number, generation);
        Assert.NotNull(held);
        // The control: the marker is real and the session is its one holder.
        Assert.Contains(Marker, Assert.IsType<CaptureContext.Available>(held).Sentence);
        inspected.Add(held!.ToString());

        // 2 — A settlement: the reading answers with the sentence; the session takes it, the consumers see nothing.
        PendingContext reading = pending.Start(new CaptureContext.Unavailable("notCaptured"), TimeSpan.FromSeconds(30),
            () => Task.FromResult<CaptureContext?>(new CaptureContext.Available(Sentence, Sentence.IndexOf(Term, StringComparison.Ordinal), Term.Length)));
        CapturedTerm waiting = Term_(new CaptureContext.Pending(reading.Handle));
        CaptureRequest two = book.Begin(CaptureTrigger.PointerGesture);
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(waiting, two, consumer));
        int waitingGeneration = consumer.Delivered[^1].Generation;
        session.Hold(waiting, two.Number, waitingGeneration);
        await reading.Finished;
        await Task.Delay(50);
        CaptureContext? settled = session.Context(two.Number, waitingGeneration);
        Assert.NotNull(settled);
        Assert.Contains(Marker, Assert.IsType<CaptureContext.Available>(settled).Sentence);
        inspected.Add(settled.ToString());
        inspected.Add(reading.ToString());
        Assert.Null(book.Terminal(two)); // a settlement acknowledges nothing nobody drew

        // 3 — A cancellation: the reading is dropped and the request ends cancelled.
        using var forever = new CancellationTokenSource();
        PendingContext cancelledReading = pending.Start(new CaptureContext.Unavailable("notCaptured"),
            TimeSpan.FromSeconds(30), async () =>
            {
                try { await Task.Delay(Timeout.Infinite, forever.Token); } catch (OperationCanceledException) { }
                return null;
            });
        CapturedTerm dropping = Term_(new CaptureContext.Pending(cancelledReading.Handle));
        CaptureRequest three = book.Begin(CaptureTrigger.Selection);
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(dropping, three, consumer));
        int droppingGeneration = consumer.Delivered[^1].Generation;
        session.Hold(dropping, three.Number, droppingGeneration);
        session.End(three.Number);
        Assert.True(session.IsEmpty);
        inspected.Add(cancelledReading.ToString());
        Assert.True(book.Cancel(three));

        // 4 — A replacement: another presentation replaces the held sentence, and closing drops it.
        CaptureRequest four = book.Begin(CaptureTrigger.Service);
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(Term_(), four, consumer));
        session.Hold(Term_(), four.Number, consumer.Delivered[^1].Generation);
        session.Clear();
        Assert.True(session.IsEmpty);
        inspected.Add(four.ToString());

        // 5 — The refusal path: a consumer that refuses ends the request cancelled.
        var refusing = new Consumer(refusing: true);
        CaptureRequest five = book.Begin(CaptureTrigger.Menu);
        Assert.Equal(CaptureDeliveryAnswer.Refused, book.Deliver(Term_(), five, refusing));
        Assert.Equal(CaptureOutcome.Cancelled, book.Terminal(five)?.Outcome);
        inspected.AddRange(refusing.Recorded);
        inspected.Add(five.ToString());

        // The canary: no string a consumer could write names the sentence.
        List<string> leaked = inspected.Where(text => text.Contains(Marker)).ToList();
        Assert.True(leaked.Count == 0, "the sentence escaped the session: " + string.Join(" | ", leaked));
        forever.Cancel();
    }
}

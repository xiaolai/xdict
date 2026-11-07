// **The terminal act of one presentation through the production coordinator** (plan §2.2, D14): the book's
// acknowledgement decides whether the delivery still owns the panel, and only a drawn entry that owns it writes a
// reading. The cases the app's controller cannot be asked directly — a superseded delivery, a failed render, the
// no-results placeholder — are the ones this file drives, against the real service and the tiny fixture.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;
using XDict.Models;
using Xunit;

public class ReadingDeliveryTests
{
    private const string Sentence = "The run began at dawn.";

    private sealed class Sink : ICaptureSink
    {
        public CaptureDelivery? Delivered { get; private set; }

        public CaptureDeliveryAnswer Deliver(CaptureDelivery delivery)
        {
            Delivered = delivery;
            return CaptureDeliveryAnswer.Accepted;
        }
    }

    private sealed class Fixture : IDisposable
    {
        public Fixture(ServiceClient client, string edition) { Client = client; Edition = edition; }
        public ServiceClient Client { get; }
        public string Edition { get; }
        public void Dispose() => Client.Dispose();
    }

    private static Fixture OpenTiny()
    {
        var client = new ServiceClient(
            Environment.GetEnvironmentVariable("XDICT_SERVICE")
                ?? throw new InvalidOperationException("XDICT_SERVICE names the built xdict-service executable"),
            new ServiceClientOptions { Storage = "reading-delivery-" + Guid.NewGuid().ToString("N") });
        try
        {
            string dir = Path.Combine(Environment.GetEnvironmentVariable("XDICT_FIXTURES")!, "tiny");
            object[] files =
            [
                client.Observe("tiny.mdx", "tiny.mdx", Path.Combine(dir, "tiny.mdx")),
                client.Observe("tiny.mdd", "tiny.mdd", Path.Combine(dir, "tiny.mdd")),
                client.Observe("tiny.css", "tiny.css", Path.Combine(dir, "tiny.css")),
            ];
            var package = new
            {
                mdx = new { file = "tiny.mdx" },
                mdd = new[] { new { file = "tiny.mdd" } },
                sidecars = new[] { new { file = "tiny.css" } },
            };
            Assert.Null(client.Call("import", new { package, progress = false }, files).Error);
            Reply opened = client.Call("open", new { package }, files);
            Assert.Null(opened.Error);
            return new Fixture(client, opened.Ok!.Value.GetProperty("edition").GetString()!);
        }
        catch
        {
            client.Dispose();
            throw;
        }
    }

    private static CapturedTerm Term(string? sentence = Sentence) =>
        CapturedTerm.From(CaptureValue.Make(JsonSerializer.SerializeToNode(sentence is null
            ? (object)new { term = "run", confidence = 1, context = new { kind = "unavailable", reason = "notCaptured" } }
            : new
            {
                term = "run",
                confidence = 1,
                context = new { kind = "available", sentence, term = new { start = 4, length = 3 } },
            })!))!;

    private static SearchHit Hit(string edition) => new(
        edition, "Tiny",
        JsonSerializer.SerializeToElement(new { edition, key = "run", occurrence = 0 }), "run", "exact", []);

    private static LibraryDictionary Dictionary(string edition) =>
        new(edition, "lineage", "Tiny", "Tiny", true, 0, "en", "zh", []);

    private static LearningSettings On() => new() { HistoryEnabled = true, HistoryDisclosed = true };

    private static string DevicePath() =>
        Path.Combine(Path.GetTempPath(), "xdict-device-" + Guid.NewGuid().ToString("N"));

    /// <summary>One request that claimed the panel and was delivered, as the controller receives it.</summary>
    private static CaptureDelivery Presentation(CaptureRequests book, CapturedTerm term)
    {
        CaptureRequest request = book.BeginPresenting(CaptureTrigger.Selection);
        var sink = new Sink();
        Assert.Equal(CaptureDeliveryAnswer.Accepted, book.Deliver(term, request, sink));
        Assert.NotNull(sink.Delivered);
        return sink.Delivered!;
    }

    /// <summary>The sentences the drawer would show: the log's own readings, not a projected count.</summary>
    private static List<string> Sentences(ServiceClient client)
    {
        double now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        Reply reply = client.Call("ledgerHistory", new { now, utcOffsetSeconds = 0 });
        Assert.Null(reply.Error);
        return reply.Ok!.Value.GetProperty("days").EnumerateArray()
            .SelectMany(day => day.GetProperty("cards").EnumerateArray())
            .Select(card => card.GetProperty("reading").GetProperty("sentence").GetString()!)
            .ToList();
    }

    [Fact]
    public async Task ADrawnEntryRecordsOneReadingAndTheRequestEndsOnce()
    {
        using Fixture fixture = OpenTiny();
        string device = DevicePath();
        try
        {
            var deliveries = new ReadingDelivery(new ReadingRecorder(fixture.Client));
            var book = new CaptureRequests();
            CaptureDelivery delivery = Presentation(book, Term());
            ReadingDelivery.Outcome ended = deliveries.Complete(delivery, book, Hit(fixture.Edition),
                Dictionary(fixture.Edition), On(), device);
            Assert.NotNull(ended.Acknowledged);
            Assert.Equal(CaptureOutcome.Shown, ended.Acknowledged!.Outcome);
            Assert.NotNull(ended.Recording);
            await ended.Recording!;
            Assert.Equal(Sentence, Assert.Single(Sentences(fixture.Client)));

            // The request ended with that acknowledgement: a repeated completion acknowledges nothing and writes
            // nothing, which is the "exactly one terminal acknowledgement" rule seen from the recording side.
            ReadingDelivery.Outcome again = deliveries.Complete(delivery, book, Hit(fixture.Edition),
                Dictionary(fixture.Edition), On(), device);
            Assert.Null(again.Acknowledged);
            Assert.Null(again.Recording);
            Assert.Single(Sentences(fixture.Client));
        }
        finally { File.Delete(device); }
    }

    [Fact]
    public void ASupersededDeliveryNeitherAcknowledgesNorRecords()
    {
        using Fixture fixture = OpenTiny();
        var deliveries = new ReadingDelivery(new ReadingRecorder(fixture.Client));
        var book = new CaptureRequests();
        CaptureDelivery stale = Presentation(book, Term());
        // A newer gesture claims the panel: the older request ends cancelled and no longer owns anything.
        _ = book.BeginPresenting(CaptureTrigger.PointerGesture);
        Assert.False(book.IsCurrent(stale.Request));
        ReadingDelivery.Outcome ended = deliveries.Complete(stale, book, Hit(fixture.Edition),
            Dictionary(fixture.Edition), On(), DevicePath());
        Assert.Null(ended.Acknowledged);
        Assert.Null(ended.Recording);
        Assert.Empty(Sentences(fixture.Client));
    }

    [Fact]
    public void AFailedRenderAndTheNoResultsPlaceholderAcknowledgeButRecordNothing()
    {
        using Fixture fixture = OpenTiny();
        var deliveries = new ReadingDelivery(new ReadingRecorder(fixture.Client));
        var book = new CaptureRequests();
        // A render that failed before any entry drew: the request still ends, spoken as `shown`.
        CaptureDelivery failed = Presentation(book, Term());
        ReadingDelivery.Outcome one = deliveries.Complete(failed, book, null, null, On(), DevicePath());
        Assert.NotNull(one.Acknowledged);
        Assert.Equal(CaptureOutcome.Shown, one.Acknowledged!.Outcome);
        Assert.Null(one.Recording);
        // The no-results placeholder draws and ends `shown` with no entry: a separate delivery, the same no record.
        CaptureDelivery placeholder = Presentation(book, Term());
        ReadingDelivery.Outcome two = deliveries.Complete(placeholder, book, null, null, On(), DevicePath());
        Assert.NotNull(two.Acknowledged);
        Assert.Equal(CaptureOutcome.Shown, two.Acknowledged!.Outcome);
        Assert.Null(two.Recording);
        Assert.Empty(Sentences(fixture.Client));
    }

    [Fact]
    public void TheSwitchAndTheSentenceEachStopTheRecord()
    {
        using Fixture fixture = OpenTiny();
        var deliveries = new ReadingDelivery(new ReadingRecorder(fixture.Client));
        var book = new CaptureRequests();
        CaptureDelivery switchedOff = Presentation(book, Term());
        ReadingDelivery.Outcome off = deliveries.Complete(switchedOff, book, Hit(fixture.Edition),
            Dictionary(fixture.Edition), new LearningSettings(), DevicePath());
        Assert.NotNull(off.Acknowledged);
        Assert.Null(off.Recording);

        CaptureDelivery noSentence = Presentation(book, Term(sentence: null));
        ReadingDelivery.Outcome none = deliveries.Complete(noSentence, book, Hit(fixture.Edition),
            Dictionary(fixture.Edition), On(), DevicePath());
        Assert.NotNull(none.Acknowledged);
        Assert.Null(none.Recording);
        Assert.Empty(Sentences(fixture.Client));
    }
}

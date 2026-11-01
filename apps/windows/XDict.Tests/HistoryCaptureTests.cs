// The record-from-reading path (plan §2.2, D14): only an entry that drew, for the current delivery, with a sentence
// captured and the history switch on. The positive case runs through the production client and service.
using System.Text.Json;
using System.Text.Json.Nodes;
using XDict.Client;
using XDict.Contract;
using XDict.Models;
using Xunit;

public class HistoryCaptureTests
{
    private static CapturedTerm Term(string term, string? sentence) =>
        CapturedTerm.From(CaptureValue.Make(JsonSerializer.SerializeToNode(sentence is null
            ? (object)new { term, confidence = 1, context = new { kind = "unavailable", reason = "notCaptured" } }
            : new
            {
                term,
                confidence = 1,
                context = new
                {
                    kind = "available",
                    sentence,
                    term = new { start = 4, length = 3 },
                },
            })!))
        ?? throw new InvalidOperationException("the capture value was refused");

    private static SearchHit Hit(string edition) => new(
        edition, "Tiny",
        JsonSerializer.SerializeToElement(new { edition, key = "run", occurrence = 0 }),
        "run", "exact", []);

    private static LibraryDictionary Dictionary(string edition) =>
        new(edition, "lineage", "Tiny", "Tiny", true, 0, "en", "zh", []);

    [Fact]
    public void TheFourFactsDecide()
    {
        Assert.True(HistoryCapture.Records(true, true, true, true, true));
        Assert.False(HistoryCapture.Records(false, true, true, true, true));
        Assert.False(HistoryCapture.Records(true, false, true, true, true));
        Assert.False(HistoryCapture.Records(true, true, false, true, true)); // the no-results placeholder
        Assert.False(HistoryCapture.Records(true, true, true, false, true)); // no sentence
        Assert.False(HistoryCapture.Records(true, true, true, true, false)); // the history is off
    }

    [Fact]
    public void AReadingCarriesTheCaptureFacts()
    {
        CapturedTerm term = Term("run", "The run began at dawn.");
        JsonElement reading = JsonSerializer.SerializeToElement(
            ReadingRecorder.Reading(term, Hit("edition-1"), Dictionary("edition-1"), 123.0, "device-1"));
        Assert.Equal("run", reading.GetProperty("surface").GetString());
        Assert.Equal("run", reading.GetProperty("lemma").GetString());
        Assert.Equal("The run began at dawn.", reading.GetProperty("sentence").GetString());
        Assert.Equal(4u, reading.GetProperty("span").GetProperty("start").GetUInt32());
        Assert.Equal(3u, reading.GetProperty("span").GetProperty("len").GetUInt32());
        Assert.Equal("edition-1", reading.GetProperty("edition").GetString());
        Assert.Equal("run", reading.GetProperty("entryKey").GetString());
        Assert.Equal(0u, reading.GetProperty("occurrence").GetUInt32());
        Assert.Equal("Tiny", reading.GetProperty("dictionaryName").GetString());
        Assert.Equal("en", reading.GetProperty("language").GetString());
        Assert.Equal(0, reading.GetProperty("cut").GetByte());
        Assert.Equal("complete", reading.GetProperty("quality").GetString());
        Assert.Equal("device-1", reading.GetProperty("device").GetString());
        Assert.Throws<InvalidOperationException>(() =>
            ReadingRecorder.Reading(Term("run", null), Hit("edition-1"), Dictionary("edition-1"), 1.0, "device-1"));
    }

    [Fact]
    public void TheDeviceIsMintedOnce()
    {
        string path = Path.Combine(Path.GetTempPath(), "xdict-device-" + Guid.NewGuid().ToString("N"));
        string other = path + "-other";
        try
        {
            string first = DeviceIdentity.Current(path);
            Assert.Equal(first, DeviceIdentity.Current(path));
            Assert.NotEqual(first, DeviceIdentity.Current(other));
        }
        finally
        {
            File.Delete(path);
            File.Delete(other);
        }
    }

    [Fact]
    public async Task ADrawnEntryRecordsOneReadingAndTheWrongCasesRecordNone()
    {
        string service = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE names the built xdict-service executable");
        using var client = new ServiceClient(service,
            new ServiceClientOptions { Storage = "history-" + Guid.NewGuid().ToString("N") });
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
        string edition = opened.Ok!.Value.GetProperty("edition").GetString()!;

        string device = Path.Combine(Path.GetTempPath(), "xdict-device-" + Guid.NewGuid().ToString("N"));
        var recorder = new ReadingRecorder(client);
        try
        {
            LearningSettings on = new() { HistoryEnabled = true };
            CapturedTerm term = Term("run", "The run began at dawn.");
            Assert.Equal(LedgerRecordOutcome.Recorded,
                await recorder.RecordAsync(term, Hit(edition), Dictionary(edition), on, device));

            double now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            JsonElement days = client.Call("ledgerHistory", new { now, utcOffsetSeconds = 0 }).Ok!.Value;
            List<JsonElement> cards = days.GetProperty("days").EnumerateArray()
                .SelectMany(day => day.GetProperty("cards").EnumerateArray()).ToList();
            Assert.Single(cards);
            Assert.Equal("The run began at dawn.",
                cards[0].GetProperty("reading").GetProperty("sentence").GetString());

            // No sentence: the capture owned no context, so nothing is written.
            Assert.Null(await recorder.RecordAsync(Term("run", null), Hit(edition), Dictionary(edition), on, device));
            // The switch is off: nothing is written.
            Assert.Null(await recorder.RecordAsync(term, Hit(edition), Dictionary(edition), new LearningSettings(), device));
            JsonElement after = client.Call("ledgerHistory", new { now, utcOffsetSeconds = 0 }).Ok!.Value;
            Assert.Single(after.GetProperty("days").EnumerateArray()
                .SelectMany(day => day.GetProperty("cards").EnumerateArray()));
        }
        finally
        {
            File.Delete(device);
        }
    }
}

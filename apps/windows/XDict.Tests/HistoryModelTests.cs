// WS-P2's non-window half through the production service: the days, the drawer's language filter, removal and undo,
// the card's gloss, the first-run disclosure, and the canary that a non-target language writes no sentence.
using System.Text.Json;
using System.Text.Json.Nodes;
using XDict.Client;
using XDict.Contract;
using XDict.Models;
using Xunit;

public class HistoryModelTests
{
    private const double At = 1_800_000_000;

    private static (ServiceClient Client, string Dict, string Edition) OpenTiny()
    {
        ServiceClient client = new(
            Environment.GetEnvironmentVariable("XDICT_SERVICE")
                ?? throw new InvalidOperationException("XDICT_SERVICE names the built xdict-service executable"),
            new ServiceClientOptions { Storage = "history-model-" + Guid.NewGuid().ToString("N") });
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
        JsonElement ok = opened.Ok!.Value;
        return (client, ok.GetProperty("dict").GetString()!, ok.GetProperty("edition").GetString()!);
    }

    private static object Reading(string edition, string sentence, string language) => new
    {
        surface = "run",
        lemma = "run",
        sentence,
        span = (object?)null,
        cut = (byte)0,
        quality = "complete",
        edition,
        entryKey = "run",
        occurrence = 0u,
        dictionaryName = "Tiny",
        language,
        at = At,
        device = "device-a",
    };

    [Fact]
    public async Task TheHistoryShowsFiltersAndRemovesAndRestoresACard()
    {
        var (client, _, edition) = OpenTiny();
        using (client)
        {
            foreach ((string sentence, string language) in new[]
                     {
                         ("The run began at dawn.", "en"),
                         ("Le run commença à l'aube.", "fr"),
                     })
            {
                Reply recorded = client.Call("ledgerRecord", new
                {
                    reading = Reading(edition, sentence, language),
                    operation = "reading-" + Guid.NewGuid().ToString("N"),
                    targetLanguages = Array.Empty<string>(),
                });
                Assert.Null(recorded.Error);
            }

            var session = new HistorySession(client,
                settings: () => new LearningSettings { HistoryEnabled = true, HistoryDisclosed = true },
                now: () => At, utcOffset: () => 0, device: () => "device-a");
            await session.LoadAsync();
            Assert.Equal(2, session.Cards.Count);
            Assert.Single(session.Visible(["en"]));
            Assert.Single(session.Visible(["fr"]));
            Assert.Equal(2, session.Visible([]).Count);
            Assert.Empty(session.Visible(["de"]));

            HistoryCard english = session.Visible(["en"]).Single();
            Assert.Equal("recorded", (await session.RemoveAsync(english)).Outcome);
            Assert.Single(session.Cards);
            Assert.Equal("recorded", (await session.RestoreAsync(english)).Outcome);
            Assert.Equal(2, session.Cards.Count);

            HistoryGloss gloss = await session.GlossAsync(english);
            Assert.Equal(edition, gloss.Entry.Edition);
            Assert.Equal("run", gloss.Entry.Key);
        }
    }

    [Fact]
    public void TheFirstRunDisclosureTurnsTheHistoryOn()
    {
        string path = Path.Combine(Path.GetTempPath(), "xdict-learning-" + Guid.NewGuid().ToString("N") + ".json");
        string? previous = Environment.GetEnvironmentVariable("XDICT_LEARNING");
        Environment.SetEnvironmentVariable("XDICT_LEARNING", path);
        try
        {
            using var client = new ServiceClient(
                Environment.GetEnvironmentVariable("XDICT_SERVICE")!);
            var session = new HistorySession(client);
            Assert.True(session.NeedsDisclosure);
            LearningSettings next = session.Disclose();
            Assert.True(next.HistoryEnabled);
            Assert.True(next.HistoryDisclosed);
            Assert.False(session.NeedsDisclosure);
            LearningSettings read = LearningSettings.Load();
            Assert.True(read.HistoryEnabled);
            Assert.True(read.HistoryDisclosed);
        }
        finally
        {
            File.Delete(path);
            Environment.SetEnvironmentVariable("XDICT_LEARNING", previous);
        }
    }

    [Fact]
    public async Task ANonTargetLanguageWritesNoSentence()
    {
        var (client, _, edition) = OpenTiny();
        using (client)
        {
            string rejected = "REJECTED-" + Guid.NewGuid().ToString("N");
            string accepted = "ACCEPTED-" + Guid.NewGuid().ToString("N");
            CapturedTerm Term(string sentence) => CapturedTerm.From(CaptureValue.Make(JsonSerializer.SerializeToNode(new
            {
                term = "run",
                confidence = 1,
                context = new { kind = "available", sentence, term = new { start = 4, length = 3 } },
            })!))!;
            var hit = new SearchHit(edition, "Tiny",
                JsonSerializer.SerializeToElement(new { edition, key = "run", occurrence = 0 }), "run", "exact", []);
            var dictionary = new LibraryDictionary(edition, "lineage", "Tiny", "Tiny", true, 0, "en", "zh", []);
            var settings = new LearningSettings
            {
                HistoryEnabled = true,
                HistoryDisclosed = true,
                TargetLanguages = ["fr"],
            };
            string devicePath = Path.Combine(Path.GetTempPath(), "xdict-device-" + Guid.NewGuid().ToString("N"));
            try
            {
                var recorder = new ReadingRecorder(client);
                Assert.Equal(LedgerRecordOutcome.SkippedLanguage, await recorder.RecordAsync(
                    Term("The run began at dawn. " + rejected), hit, dictionary, settings, devicePath));
                // An accepted language writes, so the absence below is the language filter and not a broken path.
                Assert.Equal(LedgerRecordOutcome.Recorded, await recorder.RecordAsync(
                    Term("The run began at dawn. " + accepted), hit, dictionary,
                    settings with { TargetLanguages = [] }, devicePath));
                // The event log itself, not the projected history: an empty card list does not prove the rejected
                // sentence never reached the log.
                string export = Path.Combine(Path.GetTempPath(), "xdict-export-" + Guid.NewGuid().ToString("N") + ".json");
                try
                {
                    await new DataExport(client).ExportAsync(export);
                    string stored = File.ReadAllText(export);
                    Assert.Contains(accepted, stored);
                    Assert.DoesNotContain(rejected, stored);
                }
                finally { File.Delete(export); }
                // The drawer keeps the last MAX_DAYS (14) only, and the recorder stamps the reading with the real
                // clock: asking with the test's fixed day would drop the reading before the assertion saw it.
                var session = new HistorySession(client, settings: () => settings,
                    now: () => DateTimeOffset.UtcNow.ToUnixTimeSeconds(), utcOffset: () => 0,
                    device: () => "device-a");
                await session.LoadAsync();
                var card = Assert.Single(session.Cards);
                Assert.Contains(accepted, card.Reading.Sentence);
            }
            finally { File.Delete(devicePath); }
        }
    }
}

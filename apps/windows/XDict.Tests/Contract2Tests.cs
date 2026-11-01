// Contract 2 through the production client, pipe and service: the learning set, edition admission, the recording
// path's storage, the client's reopen after a service restart, and the 4 MiB envelope's two sides.
using System.Diagnostics;
using System.Text.Json;
using XDict.Client;
using XDict.Contract;
using Xunit;

public class Contract2Tests
{
    private static ServiceClient Start() => new(
        Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE names the built xdict-service executable"),
        new ServiceClientOptions { Storage = "contract2-" + Guid.NewGuid().ToString("N") });

    private static JsonElement Ok(Reply reply)
    {
        if (reply.Error is { } error) throw new InvalidOperationException("the service refused: " + error);
        return reply.Ok ?? throw new InvalidOperationException("the reply has no answer");
    }

    private static string Error(Reply reply) =>
        reply.Error is { } error ? error.GetProperty("type").GetString()! : "";

    private static (ServiceClient Client, string Dict, string Edition) OpenTiny()
    {
        ServiceClient client = Start();
        string dir = Path.Combine(Environment.GetEnvironmentVariable("XDICT_FIXTURES")
            ?? throw new InvalidOperationException("XDICT_FIXTURES names the generated conformance fixtures"), "tiny");
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
        Reply imported = client.Call("import", new { package, progress = false }, files);
        Assert.Null(imported.Error);
        Reply opened = client.Call("open", new { package }, files);
        Assert.Null(opened.Error);
        JsonElement ok = Ok(opened);
        return (client, ok.GetProperty("dict").GetString()!, ok.GetProperty("edition").GetString()!);
    }

    private static List<JsonElement> Cards(JsonElement history) =>
        history.GetProperty("days").EnumerateArray()
            .SelectMany(day => day.GetProperty("cards").EnumerateArray())
            .ToList();

    private static string TargetKey(JsonElement target) =>
        $"{target.GetProperty("lineage").GetString()}\u001f{target.GetProperty("entryKey").GetString()}"
        + $"\u001f{target.GetProperty("occurrence").GetUInt32()}\u001f{target.GetProperty("kind").GetString()}";

    private static object Reading(string sentence, string edition, double at, string device) => new
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
        language = "en",
        at,
        device,
    };

    [Fact]
    public void TheLearningSetAnswersThroughTheProductionPipe()
    {
        var (client, dict, edition) = OpenTiny();
        using (client)
        {
            double at = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var stamp = new { at, device = "contract2" };
            var entry = new { edition, key = "run", occurrence = 0 };

            Reply gloss = client.Call("entryGloss", new { entry });
            Assert.Null(gloss.Error);
            Assert.Equal(edition, Ok(gloss).GetProperty("entry").GetProperty("edition").GetString());

            var reading = Reading("The run began at dawn.", edition, at, "contract2");
            Reply recorded = client.Call("ledgerRecord", new
            {
                reading,
                operation = "reading-" + Guid.NewGuid().ToString("N"),
                targetLanguages = new[] { "en" },
            });
            Assert.Null(recorded.Error);
            Assert.Equal("recorded", Ok(recorded).GetString());

            JsonElement history = Ok(client.Call("ledgerHistory", new { now = at, utcOffsetSeconds = 0 }));
            List<JsonElement> cards = Cards(history);
            Assert.NotEmpty(cards);
            string[] events = cards[0].GetProperty("events").EnumerateArray().Select(e => e.GetString()!).ToArray();
            Assert.NotEmpty(events);

            Reply removed = client.Call("ledgerRemove", new
            {
                removal = new { eventIds = events, at, device = "contract2" },
                operation = "remove-" + Guid.NewGuid().ToString("N"),
            });
            Assert.Null(removed.Error);
            Assert.Empty(Cards(Ok(client.Call("ledgerHistory", new { now = at, utcOffsetSeconds = 0 }))));

            Reply restored = client.Call("ledgerRestore", new
            {
                removal = new { eventIds = events, at, device = "contract2" },
                operation = "restore-" + Guid.NewGuid().ToString("N"),
            });
            Assert.Null(restored.Error);
            Assert.NotEmpty(Cards(Ok(client.Call("ledgerHistory", new { now = at, utcOffsetSeconds = 0 }))));

            Reply noteAt = client.Call("studyNoteAt", new
            {
                entry,
                text = "my note",
                name = "Tiny",
                stamp,
                operation = "note-at-" + Guid.NewGuid().ToString("N"),
            });
            Assert.Null(noteAt.Error);
            Assert.Equal("my note", Ok(noteAt).GetProperty("text").GetString());

            Reply note = client.Call("studyNote", new
            {
                dict,
                entry,
                text = "my second note",
                name = "Tiny",
                stamp,
                operation = "note-" + Guid.NewGuid().ToString("N"),
            });
            Assert.Null(note.Error);
            Assert.Equal("my second note", Ok(note).GetProperty("text").GetString());
            Assert.NotEmpty(Ok(client.Call("studyNotes", null)).EnumerateArray());

            Reply hash = client.Call("definitionHash", new { dict, entry });
            Assert.Null(hash.Error);
            Assert.False(string.IsNullOrWhiteSpace(Ok(hash).GetString()));

            Reply reanchored = client.Call("studyReanchor", new
            {
                oldEdition = edition,
                newEdition = edition,
                stamp,
                operationPrefix = "reanchor-" + Guid.NewGuid().ToString("N"),
            });
            Assert.Null(reanchored.Error);
            Assert.NotEmpty(Ok(reanchored).GetProperty("outcomes").EnumerateArray());

            JsonElement queue = Ok(client.Call("reviewQueue", new { now = at, limit = 20u }));
            JsonElement card = queue.EnumerateArray().First(c => c.GetProperty("target").GetProperty("entryKey").GetString() == "run");
            string target = TargetKey(card.GetProperty("target"));
            string head = card.GetProperty("head").GetString()!;

            Reply graded = client.Call("reviewGrade", new
            {
                target,
                revision = head,
                grade = "good",
                policy = new { retention = 0.9, maximumDays = 36500 },
                stamp,
                operation = "grade-" + Guid.NewGuid().ToString("N"),
            });
            Assert.Null(graded.Error);
            JsonElement outcome = Ok(graded);
            Assert.Equal("recorded", outcome.GetProperty("outcome").GetString());
            string gradeEvent = outcome.GetProperty("card").GetProperty("head").GetString()!;

            Assert.Null(client.Call("reviewSummary", new { now = at }).Error);
            Reply undone = client.Call("reviewUndo", new
            {
                target,
                gradeEvent,
                stamp,
                operation = "undo-" + Guid.NewGuid().ToString("N"),
            });
            Assert.Null(undone.Error);
            Assert.Empty(Ok(client.Call("studyConflicts", null)).EnumerateArray());

            Reply exported = client.Call("exportData", null);
            Assert.Null(exported.Error);
            using (JsonDocument document = JsonDocument.Parse(exported.Payload!))
            {
                Assert.Equal(1, document.RootElement.GetProperty("version").GetInt32());
                Assert.NotEmpty(document.RootElement.GetProperty("events").EnumerateArray());
            }

            Reply erased = client.Call("eraseData", new
            {
                stamp,
                operation = "erase-" + Guid.NewGuid().ToString("N"),
            });
            Assert.Null(erased.Error);
            Assert.True(Ok(erased).GetProperty("clearedReadings").GetUInt64() >= 1);
            Assert.Empty(Cards(Ok(client.Call("ledgerHistory", new { now = at, utcOffsetSeconds = 0 }))));
            Assert.Null(client.Call("close", new { dict }).Error);
        }
    }

    [Fact]
    public void AFreshServiceAnswersNotFoundForAnEditionAndTheClientReopensIt()
    {
        using ServiceClient client = Start();
        string missing = "mdx-sha256-v1:" + new string('0', 64);
        Reply absent = client.Call("entryGloss", new
        {
            entry = new { edition = missing, key = "run", occurrence = 0 },
        });
        Assert.Equal("notFound", Error(absent));
        Assert.Equal("edition", absent.Error!.Value.GetProperty("what").GetString());

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
        string edition = Ok(opened).GetProperty("edition").GetString()!;
        var entry = new { edition, key = "run", occurrence = 0 };

        int first = client.ProcessId;
        Assert.Null(client.Call("entryGloss", new { entry }).Error);
        using (Process process = Process.GetProcessById(first))
        {
            process.Kill();
            process.WaitForExit();
        }
        Reply after = client.Call("entryGloss", new { entry });
        Assert.Null(after.Error);
        Assert.NotEqual(first, client.ProcessId);
    }

    [Fact]
    public void AnEnvelopeOverFourMebibytesIsRefusedWithoutEndingTheConnection()
    {
        using ServiceClient client = Start();
        double at = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var stamp = new { at, device = "contract2" };

        string tooBig = new('x', 4_200_000);
        Reply over = client.Call("ledgerRecord", new
        {
            reading = Reading(tooBig, "mdx-sha256-v1:contract2", at, "contract2"),
            operation = "over-" + Guid.NewGuid().ToString("N"),
            targetLanguages = new[] { "en" },
        });
        Assert.Equal("envelopeTooLarge", Error(over));
        Assert.NotNull(client.Handshake());

        string large = new('y', 2_200_000);
        string other = new('z', 2_200_000);
        Assert.Null(client.Call("ledgerRecord", new
        {
            reading = Reading(large, "mdx-sha256-v1:contract2", at, "contract2"),
            operation = "large-1-" + Guid.NewGuid().ToString("N"),
            targetLanguages = new[] { "en" },
        }).Error);
        Assert.Null(client.Call("ledgerRecord", new
        {
            reading = Reading(other, "mdx-sha256-v1:contract2", at, "contract2"),
            operation = "large-2-" + Guid.NewGuid().ToString("N"),
            targetLanguages = new[] { "en" },
        }).Error);

        Reply history = client.Call("ledgerHistory", new { now = at, utcOffsetSeconds = 0 });
        Assert.Equal("envelopeTooLarge", Error(history));
        Assert.Equal((uint)Wire.JsonMax, history.Error!.Value.GetProperty("ceiling").GetUInt32());
        Assert.NotNull(client.Handshake());

        Reply erased = client.Call("eraseData", new
        {
            stamp,
            operation = "erase-big-" + Guid.NewGuid().ToString("N"),
        });
        Assert.Null(erased.Error);
        Assert.NotNull(client.Handshake());
    }
}

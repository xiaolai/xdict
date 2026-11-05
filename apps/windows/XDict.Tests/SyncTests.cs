// Contract 3's two-store sync through the production client and service: A's reading reaches B, B's note and grade
// reach A, and each device's own log is excluded from its input. The folder is the reader's; the service stages it.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;
using XDict.Models;
using Xunit;

public class SyncTests
{
    private const double At = 1_800_000_000;

    private static (ServiceClient Client, string Edition) OpenTiny(string storage)
    {
        ServiceClient client = new(
            Environment.GetEnvironmentVariable("XDICT_SERVICE")
                ?? throw new InvalidOperationException("XDICT_SERVICE names the built xdict-service executable"),
            new ServiceClientOptions { Storage = storage });
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
        return (client, opened.Ok!.Value.GetProperty("edition").GetString()!);
    }

    private static JsonElement History(ServiceClient client)
    {
        Reply reply = client.Call("ledgerHistory", new { now = At, utcOffsetSeconds = 0 });
        Assert.Null(reply.Error);
        return reply.Ok!.Value;
    }

    private static List<StudyCard> Queue(ServiceClient client, double now)
    {
        Reply reply = client.Call("reviewQueue", new { now, limit = 20 });
        Assert.Null(reply.Error);
        return StudyWire.Read<List<StudyCard>>(reply);
    }

    [Fact]
    public async Task TwoStoresShareReadingsNotesAndAGrade()
    {
        string folder = Path.Combine(Path.GetTempPath(), "xdict-sync-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var (a, edition) = OpenTiny("sync-a-" + Guid.NewGuid().ToString("N"));
        var (b, _) = OpenTiny("sync-b-" + Guid.NewGuid().ToString("N"));
        using (a)
        using (b)
        {
            try
            {
                Reply recorded = a.Call("ledgerRecord", new
                {
                    reading = new
                    {
                        surface = "run",
                        lemma = "run",
                        sentence = "The run began at dawn.",
                        span = (object?)null,
                        cut = (byte)0,
                        quality = "complete",
                        edition,
                        entryKey = "run",
                        occurrence = 0u,
                        dictionaryName = "Tiny",
                        language = "en",
                        at = At,
                        device = "sync-a",
                    },
                    operation = "reading-" + Guid.NewGuid().ToString("N"),
                    targetLanguages = Array.Empty<string>(),
                });
                Assert.Null(recorded.Error);

                SyncReport first = await new SyncSession(a, device: () => "sync-a").SyncAsync(folder);
                Assert.Equal(0ul, first.Peers);
                Assert.True(first.Exported > 0);
                Assert.True(File.Exists(Path.Combine(folder, "xdict-sync-a.xdlog")));

                SyncReport second = await new SyncSession(b, device: () => "sync-b").SyncAsync(folder);
                Assert.Equal(1ul, second.Peers);
                Assert.True(second.Added >= 1);
                JsonElement history = History(b);
                Assert.Equal(1, history.GetProperty("days").GetArrayLength());

                Reply note = b.Call("studyNoteAt", new
                {
                    entry = new { edition, key = "run", occurrence = 0u },
                    text = "synced note",
                    name = "Tiny",
                    stamp = new { at = At, device = "sync-b" },
                    operation = "note-" + Guid.NewGuid().ToString("N"),
                });
                Assert.Null(note.Error);

                await new SyncSession(b, device: () => "sync-b").SyncAsync(folder);
                await new SyncSession(a, device: () => "sync-a").SyncAsync(folder);
                Reply notes = a.Call("studyNotes", null);
                Assert.Null(notes.Error);
                Assert.Contains("synced note", notes.Ok!.Value.GetRawText());

                var review = new ReviewSession(a,
                    settings: () => new LearningSettings { ReviewRetention = 0.9, MaximumDays = 36500 },
                    now: () => At, device: () => "sync-a", editionAvailable: _ => true);
                await review.LoadAsync();
                Assert.NotNull(review.Current);
                Assert.True(review.Reveal());
                ReviewOutcome outcome = await review.GradeAsync(StudyGrade.Good);
                Assert.True(outcome.Written);

                await new SyncSession(a, device: () => "sync-a").SyncAsync(folder);
                await new SyncSession(b, device: () => "sync-b").SyncAsync(folder);
                // The grade moved the card past the test's fixed day; ask a year later to see the merged state.
                List<StudyCard> after = Queue(b, At + 365 * 24 * 3600);
                Assert.NotEmpty(after);
                Assert.True(after[0].Grades >= 1);
            }
            finally
            {
                Directory.Delete(folder, true);
            }
        }
    }

    [Fact]
    public async Task TheFolderBoundRefusesByCountBeforeTheService()
    {
        string folder = Path.Combine(Path.GetTempPath(), "xdict-sync-many-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        using var client = new ServiceClient(
            Environment.GetEnvironmentVariable("XDICT_SERVICE")!,
            new ServiceClientOptions { Storage = "sync-limit-" + Guid.NewGuid().ToString("N") });
        try
        {
            for (int i = 0; i < SyncSession.MaxFiles + 1; i++)
                File.WriteAllText(Path.Combine(folder, $"peer-{i}.xdlog"), "{}");
            var error = await Assert.ThrowsAsync<SyncLimitException>(() =>
                new SyncSession(client, device: () => "sync-limit").SyncAsync(folder));
            Assert.Contains(folder, error.Message);
            Assert.Contains((SyncSession.MaxFiles + 1).ToString(), error.Message);
        }
        finally
        {
            Directory.Delete(folder, true);
        }
    }

    [Fact]
    public void AWriteHandleOutsideLedgerSyncIsAdmission()
    {
        using var client = new ServiceClient(
            Environment.GetEnvironmentVariable("XDICT_SERVICE")!,
            new ServiceClientOptions { Storage = "sync-write-" + Guid.NewGuid().ToString("N") });
        string path = Path.Combine(Path.GetTempPath(), "xdict-write-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            FileObservation write = client.ObserveWrite("write", "xdict.tmp", path);
            Reply reply = client.Call("versions", null, new object[] { write });
            Assert.NotNull(reply.Error);
            Assert.Equal("admission", reply.Error!.Value.GetProperty("type").GetString());
        }
        finally
        {
            File.Delete(path);
        }
    }
}

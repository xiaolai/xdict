// WS-P3's non-window models through the production service: the review queue, reveal-before-grade, one grade and
// its undo, the note draft and its evidence, the re-anchor path, export/erase, and the reminder plan.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;
using XDict.Models;
using Xunit;

public class StudyModelsTests
{
    private const double At = 1_800_000_000;

    private static (ServiceClient Client, string Dict, string Edition) OpenTiny()
    {
        ServiceClient client = new(
            Environment.GetEnvironmentVariable("XDICT_SERVICE")
                ?? throw new InvalidOperationException("XDICT_SERVICE names the built xdict-service executable"),
            new ServiceClientOptions { Storage = "study-" + Guid.NewGuid().ToString("N") });
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

    [Fact]
    public async Task TheReviewSessionRevealsBeforeItGradesAndUndoesTheGrade()
    {
        var (client, dict, edition) = OpenTiny();
        using (client)
        {
            var entry = new { edition, key = "run", occurrence = 0 };
            var stamp = new { at = At, device = "device-a" };
            Reply note = client.Call("studyNoteAt", new
            {
                entry,
                text = "first note",
                name = "Tiny",
                stamp,
                operation = "note-" + Guid.NewGuid().ToString("N"),
            });
            Assert.Null(note.Error);

            var session = new ReviewSession(client,
                settings: () => new LearningSettings { ReviewRetention = 0.9, MaximumDays = 36500 },
                now: () => At,
                device: () => "device-a",
                editionAvailable: value => value == edition);
            await session.LoadAsync();
            Assert.NotNull(session.Current);
            Assert.True(session.CanOpen(session.Current!));
            Assert.False(session.CanGrade); // reveal-before-grade
            Assert.True(session.Reveal());
            Assert.True(session.CanGrade);

            ReviewOutcome graded = await session.GradeAsync(StudyGrade.Good);
            Assert.True(graded.Written);
            Assert.False(string.IsNullOrWhiteSpace(session.LastGradeEvent));

            ReviewOutcome undone = await session.UndoAsync();
            Assert.True(undone.Written);
            Assert.NotNull(session.Current);
            Assert.False(session.Revealed);
            Assert.False(session.CanGrade);

            var draft = new StudyNoteDraft(session.Current!, session.Current!.Note);
            draft.Edit("second note");
            Assert.True(draft.IsDirty);
            string? evidence = await draft.EvidenceAsync(client, dict);
            Assert.False(string.IsNullOrWhiteSpace(evidence));
            StudyNote saved = (await draft.SaveAsync(client, "Tiny", dict, now: () => At, device: () => "device-a"))!;
            Assert.Equal("second note", saved.Text);
            Assert.Equal(evidence, saved.Target.DefinitionHash);
            Assert.False(draft.IsDirty);
            Assert.Contains(StudyWire.Read<List<StudyNote>>(client.Call("studyNotes", null)),
                item => item.Text == "second note");

            ReanchorReport report = await session.ReanchorAsync(edition, edition);
            Assert.Contains(report.Outcomes, item => item.Result == "reanchored");
            Assert.Empty(await session.ConflictsAsync());

            string export = Path.Combine(Path.GetTempPath(), "xdict-export-" + Guid.NewGuid().ToString("N") + ".json");
            try
            {
                DataExportResult written = await new DataExport(client).ExportAsync(export);
                Assert.True(File.Exists(written.Path));
                using (JsonDocument document = JsonDocument.Parse(File.ReadAllText(export)))
                {
                    Assert.Equal(1, document.RootElement.GetProperty("version").GetInt32());
                    Assert.NotEmpty(document.RootElement.GetProperty("events").EnumerateArray());
                }
                EraseReport erased = await new DataExport(client).EraseAsync(() => At, () => "device-a");
                Assert.True(erased.ClearedNotes >= 1);
                Assert.Empty(StudyWire.Read<List<StudyNote>>(client.Call("studyNotes", null)));
                await session.LoadAsync();
                Assert.Empty(session.Cards);
            }
            finally
            {
                File.Delete(export);
            }
        }
    }

    [Fact]
    public void TheReminderPlanCoversDueNextOverduePermissionAndTheSwitch()
    {
        ReviewSummary due = new(2, null), next = new(0, 2_000), past = new(0, 500), none = new(0, null);
        ReviewReminderPlan granted = ReviewReminderPlan.Plan(1_000, due, ReminderPermission.Granted, true);
        Assert.Equal(ReminderKind.Due, granted.Kind);
        Assert.Equal(1_000, granted.At);
        Assert.True(granted.Register);
        Assert.False(granted.AskPermission);
        Assert.True(granted.CanDeliver);

        ReviewReminderPlan ask = ReviewReminderPlan.Plan(1_000, due, ReminderPermission.Unspecified, true);
        Assert.True(ask.AskPermission);
        Assert.False(ask.Register);
        Assert.False(ask.CanDeliver);

        ReviewReminderPlan denied = ReviewReminderPlan.Plan(1_000, due, ReminderPermission.Denied, true);
        Assert.Equal(ReminderKind.Due, denied.Kind);
        Assert.False(denied.Register);
        Assert.False(denied.AskPermission);

        ReviewReminderPlan later = ReviewReminderPlan.Plan(1_000, next, ReminderPermission.Granted, true);
        Assert.Equal(ReminderKind.NextDue, later.Kind);
        Assert.Equal(2_000, later.At);
        ReviewReminderPlan overdue = ReviewReminderPlan.Plan(1_000, past, ReminderPermission.Granted, true);
        Assert.Equal(ReminderKind.Overdue, overdue.Kind);
        Assert.Equal(1_000, overdue.At);
        ReviewReminderPlan off = ReviewReminderPlan.Plan(1_000, due, ReminderPermission.Granted, false);
        Assert.Equal(ReminderKind.None, off.Kind);
        Assert.False(off.Register);
        Assert.Equal(ReminderKind.None, ReviewReminderPlan.Plan(1_000, none, ReminderPermission.Granted, true).Kind);
    }

    [Fact]
    public void WindowsNotificationSettingsMapToTheReminderPermission()
    {
        Assert.Equal(ReminderPermission.Granted, ReviewReminderPlan.PermissionOf("Enabled"));
        Assert.Equal(ReminderPermission.Denied, ReviewReminderPlan.PermissionOf("DisabledForApplication"));
        Assert.Equal(ReminderPermission.Denied, ReviewReminderPlan.PermissionOf("DisabledForUser"));
        Assert.Equal(ReminderPermission.Denied, ReviewReminderPlan.PermissionOf("DisabledByGroupPolicy"));
        Assert.Equal(ReminderPermission.Unsupported, ReviewReminderPlan.PermissionOf("Unsupported"));
        // A value this build does not know is not permission to show a notification.
        Assert.Equal(ReminderPermission.Unspecified, ReviewReminderPlan.PermissionOf("SomethingNew"));
    }

    [Fact]
    public void TheTargetKeyIsTheReviewsIdentity()
    {
        var target = new StudyTarget("lineage-1", "run", 2, "entry", "edition-1", "hash");
        Assert.Equal("lineage-1\u001frun\u001f2\u001fentry", target.Key);
        Assert.Equal("good", StudyGrade.Good.Wire());
    }
}

using XDict.Models;
using Xunit;

public class HoverPolicyTests
{
    /// <summary>Both halves: a refusal must be a refusal, not merely carry a refusal enum value in a verdict that
    /// looks (HoverVerdict.Yes names ModifierNotHeld by default).</summary>
    private static void Refused(HoverVerdict verdict, HoverRefusal expected)
    {
        Assert.False(verdict.Look);
        Assert.Equal(expected, verdict.Refusal);
    }

    [Fact]
    public void TheShippedPolicyIsADeliberateHoldThatNeverReadsAPasswordManager()
    {
        var policy = new HoverPolicy();
        Assert.True(policy.Enabled);
        Assert.Equal(HoverModifier.Control, policy.Modifier);
        Assert.Equal(HoverGesture.Hold, policy.Gesture);
        Assert.Equal(HoverPolicy.DefaultSettleMs, policy.SettleMs);
        Assert.True(policy.Excludes("1Password.exe"));
        Assert.True(policy.Excludes(@"C:\Program Files\Bitwarden\Bitwarden.exe"));
        Assert.True(policy.Excludes("keepassxc.EXE"));
        Assert.False(policy.Excludes("notepad.exe"));
        Assert.False(policy.Excludes("KeePassNotes.exe"));
        Assert.False(policy.Excludes(null));
    }

    [Fact]
    public void AHoldRefusesWithoutTheKeyBeforeItLooksAtAnythingElse()
    {
        var policy = new HoverPolicy();
        Refused(policy.Decide(modifierHeld: false, tappedTwice: false, stillForMs: 5000, processName: "1Password.exe",
            wordKey: "k", lastWordKey: "k", captureInFlight: true), HoverRefusal.ModifierNotHeld);
        Assert.True(policy.Decide(modifierHeld: true, tappedTwice: false, stillForMs: 5000, processName: "notepad.exe",
            wordKey: "k", lastWordKey: null, captureInFlight: false).Look);
    }

    [Fact]
    public void ADoubleTapRefusesUntilTheTapCompletesAndDoesNotNeedTheKeyDown()
    {
        var policy = new HoverPolicy { Gesture = HoverGesture.DoubleTap };
        Refused(policy.Decide(modifierHeld: false, tappedTwice: false, stillForMs: 5000, processName: "notepad.exe",
            wordKey: null, lastWordKey: null, captureInFlight: false), HoverRefusal.NotTapped);
        Assert.True(policy.Decide(modifierHeld: false, tappedTwice: true, stillForMs: 5000, processName: "notepad.exe",
            wordKey: null, lastWordKey: null, captureInFlight: false).Look);
    }

    [Fact]
    public void EveryCheaperRefusalComesBeforeTheRestAndTheRestBeforeTheRepeat()
    {
        var policy = new HoverPolicy();
        void Refuse(long still, string process, string? last, bool inFlight, HoverRefusal expected) =>
            Refused(policy.Decide(true, false, still, process, "same", last, inFlight), expected);
        Refuse(5000, "Keeper.exe", null, false, HoverRefusal.ExcludedApp);
        Refuse(5000, "notepad.exe", null, true, HoverRefusal.CaptureInFlight);
        Refuse(299, "notepad.exe", null, false, HoverRefusal.StillMoving);
        Refuse(5000, "notepad.exe", "same", false, HoverRefusal.SamePlace);
        // Overlapping conditions: the cheapest still wins, in the declared order.
        Refuse(0, "Keeper.exe", "same", true, HoverRefusal.ExcludedApp);
        Refuse(0, "notepad.exe", "same", true, HoverRefusal.CaptureInFlight);
        Refuse(0, "notepad.exe", "same", false, HoverRefusal.StillMoving);
        Assert.True(policy.Decide(true, false, 300, "notepad.exe", "same", "other", false).Look);
    }

    [Fact]
    public void TheDifferentKeyAtTheSamePlaceIsANewRequest()
    {
        var policy = new HoverPolicy();
        Assert.True(policy.Decide(true, false, 5000, "notepad.exe", null, "word", false).Look);
        Assert.True(policy.Decide(true, false, 5000, "notepad.exe", "other", "word", false).Look);
    }

    [Fact]
    public void ATapIsTwoPressesInsideTheWindowAndNothingElseCompletesIt()
    {
        var recogniser = new HoverGestureRecognizer();
        Assert.False(recogniser.Saw(HoverGesture.DoubleTap, true, false, 0));
        Assert.False(recogniser.Saw(HoverGesture.DoubleTap, false, false, 100));
        Assert.True(recogniser.Saw(HoverGesture.DoubleTap, true, false, 300));
        // A completed pair resets: a third press starts a new pair rather than completing a second.
        Assert.False(recogniser.Saw(HoverGesture.DoubleTap, false, false, 700));
        Assert.False(recogniser.Saw(HoverGesture.DoubleTap, true, false, 900));

        var slow = new HoverGestureRecognizer();
        Assert.False(slow.Saw(HoverGesture.DoubleTap, true, false, 0));
        Assert.False(slow.Saw(HoverGesture.DoubleTap, false, false, 100));
        Assert.False(slow.Saw(HoverGesture.DoubleTap, true, false, TapCounter.WindowMs + 1));

        var chord = new HoverGestureRecognizer();
        Assert.False(chord.Saw(HoverGesture.DoubleTap, true, false, 0));
        Assert.False(chord.Saw(HoverGesture.DoubleTap, false, false, 50));
        Assert.False(chord.Saw(HoverGesture.DoubleTap, true, true, 100));
        Assert.False(chord.Saw(HoverGesture.DoubleTap, true, false, 150));
    }

    [Fact]
    public void AHoldPolicyNeverCompletesATapFromModifierTransitions()
    {
        var recogniser = new HoverGestureRecognizer();
        Assert.False(recogniser.Saw(HoverGesture.Hold, true, false, 0));
        Assert.False(recogniser.Saw(HoverGesture.Hold, false, false, 50));
        Assert.False(recogniser.Saw(HoverGesture.Hold, true, false, 100));
    }

    [Fact]
    public void AnUnknownRestFallsToTheShippedOneAndTheListIsCleaned()
    {
        HoverPolicy validated = (new HoverPolicy
        {
            SettleMs = 17,
            ExcludedApps = ["  Keeper.exe  ", "keeper.EXE", "", @"C:\secret\1Password.exe", "Bitwarden.exe"],
        }).Validated();
        Assert.Equal(HoverPolicy.DefaultSettleMs, validated.SettleMs);
        Assert.Equal(["Keeper.exe", "Bitwarden.exe"], validated.ExcludedApps);
    }

    [Fact]
    public void TheHoverChoicesSurviveARelaunchBesideTheShortcut()
    {
        string folder = Path.Combine(Path.GetTempPath(), "xdict-hover-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            string path = Path.Combine(folder, "capture.json");
            var settings = new CaptureSettings { Key = 0x4B, Hover = new HoverPolicy
            {
                Modifier = HoverModifier.Shift,
                Gesture = HoverGesture.DoubleTap,
                SettleMs = 180,
                ExcludedApps = ["Keeper.exe"],
            } };
            settings.Save(path);
            CaptureSettings loaded = CaptureSettings.Load(path);
            Assert.Equal(0x4Bu, loaded.Key);
            Assert.Equal(HoverModifier.Shift, loaded.Hover.Modifier);
            Assert.Equal(HoverGesture.DoubleTap, loaded.Hover.Gesture);
            Assert.Equal(180, loaded.Hover.SettleMs);
            Assert.Equal(["Keeper.exe"], loaded.Hover.ExcludedApps);
        }
        finally { Directory.Delete(folder, true); }
    }
}

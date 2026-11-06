// The hover gate (plan-windows-parity WS-P8, D8): whether a rest of the pointer is a request at all, and when it is
// quiet why. The whole rule is a value, so every event order is tested without a hook, a screen or a clock; the watcher
// supplies the modifier state, the rest and the process under the point, and decides nothing itself.
namespace XDict.Models;

public enum HoverGesture
{
    /// <summary>Hold the key while the pointer rests. The shipped default.</summary>
    Hold,

    /// <summary>Tap the key twice inside <see cref="TapCounter.WindowMs"/>; the key is up by the time the read runs.</summary>
    DoubleTap,
}

public enum HoverModifier
{
    Control,
    Shift,
    Alt,
    Windows,
}

public enum HoverRefusal
{
    ModifierNotHeld,
    NotTapped,
    ExcludedApp,
    CaptureInFlight,
    StillMoving,
    SamePlace,
}

/// <summary>The gate's answer: look, or stay quiet and say why. Metadata only; no sentence is named here.</summary>
public readonly record struct HoverVerdict(bool Look, HoverRefusal Refusal)
{
    public static HoverVerdict Quiet(HoverRefusal reason) => new(false, reason);
    public static readonly HoverVerdict Yes = new(true, default);
}

/// <summary>The reader's hover choices, with the platform's defaults. Persisted beside the capture shortcut in
/// <see cref="CaptureSettings"/>; read back through <see cref="CaptureSettings.Hover"/>.</summary>
public sealed record HoverPolicy
{
    /// <summary>How long the pointer must be still. The macOS release measured 180 ms; Windows' UIA hit test is the
    /// slower path, so the shipped value is the next named rest, and every rest is one the hover path was used at.</summary>
    public const int DefaultSettleMs = 300;

    /// <summary>A named list, never a free slider: 20 ms fires at every word the reader passes over.</summary>
    public static readonly int[] SettleChoices = [120, 180, 300, 500];

    /// <summary>Safety, not taste: capture takes the sentence around a word, and a password manager's whole surface is
    /// secrets (ADR-0014 decision 10). The Windows list is by executable name; matching ignores case and `.exe`.</summary>
    public static readonly string[] DefaultExcludedApps =
    [
        "1Password.exe",
        "1Password-BrowserSupport.exe",
        "Bitwarden.exe",
        "Dashlane.exe",
        "Enpass.exe",
        "KeePass.exe",
        "KeePass2.exe",
        "KeePassXC.exe",
        "Keeper.exe",
        "KeeperSecurity.exe",
        "LastPass.exe",
        "NordPass.exe",
        "RoboForm.exe",
        "StickyPassword.exe",
    ];

    public bool Enabled { get; init; } = true;

    public HoverModifier Modifier { get; init; } = HoverModifier.Control;

    public HoverGesture Gesture { get; init; } = HoverGesture.Hold;

    public int SettleMs { get; init; } = DefaultSettleMs;

    public IReadOnlyList<string> ExcludedApps { get; init; } = DefaultExcludedApps;

    public HoverPolicy Validated() => this with
    {
        Modifier = Enum.IsDefined(Modifier) ? Modifier : HoverModifier.Control,
        Gesture = Enum.IsDefined(Gesture) ? Gesture : HoverGesture.Hold,
        SettleMs = SettleChoices.Contains(SettleMs) ? SettleMs : DefaultSettleMs,
        ExcludedApps = Normalise(ExcludedApps),
    };

    private static string[] Normalise(IReadOnlyList<string>? apps) =>
        (apps ?? [])
        .Select(app => app.Trim())
        .Where(app => app.Length > 0 && app.Length <= 260 && app.IndexOfAny(['\\', '/', ':']) < 0)
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .Take(64)
        .ToArray();

    /// <summary>Whether `processName` is one of the reader's excluded programs (or a path to it).</summary>
    public bool Excludes(string? processName)
    {
        if (string.IsNullOrWhiteSpace(processName)) return false;
        string name = Path.GetFileName(processName.Trim());
        if (name.Length == 0) return false;
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
        return ExcludedApps.Any(app =>
        {
            string stored = app.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? app[..^4] : app;
            return string.Equals(stored, name, StringComparison.OrdinalIgnoreCase);
        });
    }

    /// <summary>The order is the cheapest and commonest refusal first, so a reader who is just reading pays one
    /// comparison. `wordKey` and `lastWordKey` are in-memory only and compared under the same key.</summary>
    public HoverVerdict Decide(bool modifierHeld, bool tappedTwice, long stillForMs, string? processName,
        string? wordKey, string? lastWordKey, bool captureInFlight)
    {
        if (Gesture == HoverGesture.Hold && !modifierHeld) return HoverVerdict.Quiet(HoverRefusal.ModifierNotHeld);
        if (Gesture == HoverGesture.DoubleTap && !tappedTwice) return HoverVerdict.Quiet(HoverRefusal.NotTapped);
        if (Excludes(processName)) return HoverVerdict.Quiet(HoverRefusal.ExcludedApp);
        if (captureInFlight) return HoverVerdict.Quiet(HoverRefusal.CaptureInFlight);
        if (stillForMs < SettleMs) return HoverVerdict.Quiet(HoverRefusal.StillMoving);
        if (wordKey is not null && wordKey == lastWordKey) return HoverVerdict.Quiet(HoverRefusal.SamePlace);
        return HoverVerdict.Yes;
    }
}

/// <summary>Two presses of one key, close enough together, with nothing in between. A value, so it needs no clock.</summary>
public sealed class TapCounter
{
    /// <summary>Long enough not to demand dexterity, short enough that two unrelated presses rarely fall inside it.</summary>
    public const long WindowMs = 400;

    private long? first;

    /// <summary>Whether this press completed a double-tap; a completed pair resets, so a third press starts a new pair.</summary>
    public bool Pressed(long atMs)
    {
        if (first is { } started && atMs >= started && atMs - started <= WindowMs)
        {
            first = null;
            return true;
        }
        first = atMs;
        return false;
    }

    /// <summary>Anything else the reader did cancels the pair: a chord between two presses is not a tap.</summary>
    public void Invalidate() => first = null;
}

/// <summary>The double-tap gesture as a value: modifier transitions and other input in, "did the reader just tap" out.
/// A chord (another modifier joining) cancels, the same rule other input applies.</summary>
public sealed class HoverGestureRecognizer
{
    private readonly TapCounter taps = new();
    private bool wasHeld;

    /// <summary>One modifier transition. `held` is whether the chosen modifier is down; `chord` says another modifier
    /// is down at the same time. Only the double-tap gesture can complete a tap.</summary>
    public bool Saw(HoverGesture gesture, bool held, bool chord, long atMs)
    {
        bool tapped = false;
        if (chord)
            taps.Invalidate();
        else if (gesture == HoverGesture.DoubleTap && held && !wasHeld)
            tapped = taps.Pressed(atMs);
        wasHeld = held;
        return tapped;
    }

    public void OtherInput() => taps.Invalidate();

    /// <summary>State does not outlive the watching: a half-finished pair from minutes ago must not complete.</summary>
    public void Reset()
    {
        taps.Invalidate();
        wasHeld = false;
    }
}

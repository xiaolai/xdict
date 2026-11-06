// Watches the pointer and the hover key (plan-windows-parity WS-P8). The low-level hooks do one thing: timestamp an
// event and hand it to the watcher's queue, so a provider's slow read can never hold the input path. The watcher owns
// the gate, the rest and the suppression; the reader owns the word; the controller owns the presentation.
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using XDict.Models;

namespace XDict.App.Capture;

public sealed class HoverWatcher : IDisposable
{
    private readonly HoverReader reader = new();
    private readonly Func<HoverPolicy> policy;
    private readonly CaptureRequests book;
    private readonly Func<int, int, CaptureRequest> begin;
    private readonly Action<HoverWord, CaptureRequest, int, int> present;
    private readonly Action<string> notice;
    private readonly Action? escape;
    private readonly Action<int, int>? button;
    private readonly BlockingCollection<HoverEvent> events = new();
    private readonly Thread watchThread;
    private readonly Thread hookThread;
    private readonly ManualResetEventSlim hookReady = new(false);
    private bool reading, armed, disposed, started;
    private int readGeneration;
    private uint hookThreadId;
    private IntPtr mouse, keyboard;
    private Win32.HookProc? mouseProc, keyboardProc;
    private CancellationTokenSource? inFlight;
    private CaptureRequest? inFlightRequest;
    private long lastMoveAt;
    private int lastX = int.MinValue, lastY = int.MinValue;
    private bool modifierHeld, tapped;
    private string? lastWordKey;
    private readonly Dictionary<int, CapturedWord> waiting = new();
    private readonly HoverGestureRecognizer recogniser = new();
    private long maxHookTicks;

    private sealed record CapturedWord(string Key, SelectionBox? Box);

    private enum HoverEventKind { Move, ModifierDown, ModifierUp, Other, Button }

    private readonly record struct HoverEvent(HoverEventKind Kind, int X, int Y, bool Held, long At);

    public HoverWatcher(Func<HoverPolicy> policy, CaptureRequests book, Func<int, int, CaptureRequest> begin,
        Action<HoverWord, CaptureRequest, int, int> present, Action<string> notice, Action? escape = null,
        Action<int, int>? button = null)
    {
        this.policy = policy;
        this.book = book;
        this.begin = begin;
        this.present = present;
        this.notice = notice;
        this.escape = escape;
        this.button = button;
        watchThread = new Thread(Watch) { IsBackground = true, Name = "XDict hover watcher" };
        hookThread = new Thread(Hooks) { IsBackground = true, Name = "XDict hover hooks" };
    }

    /// <summary>How long one hook callback spent in this process, in microseconds; the input path's cost.</summary>
    public long MaxHookMicroseconds => Interlocked.Read(ref maxHookTicks) * 1_000_000 / Stopwatch.Frequency;

    /// <summary>What the last rest decided or found, for the lab's evidence: metadata only.</summary>
    public string LastOutcome { get; private set; } = "";
    public long LastReadMs { get; private set; }
    /// <summary>Why the last read answered as it did: the lab and the stage print it on a miss.</summary>
    public string LastDiagnostics { get; private set; } = "";
    public int ReadsStarted { get; private set; }
    public int WordsFound { get; private set; }
    public int EventsSeen { get; private set; }
    public long LastStillMs { get; private set; }
    public int LastSettleMs { get; private set; }
    public long SettleChecks { get; private set; }
    public int ModifierDowns { get; private set; }
    public string LastEvent { get; private set; } = "";
    public bool ArmedNow => armed;
    public bool ModifierNow => modifierHeld;
    public bool ReadingNow => reading;
    public long LastEventDelayMs { get; private set; }
    public bool EnabledNow => policy().Enabled;
    public HoverWord? LastWord { get; private set; }

    public HoverReader Reader => reader;

    /// <summary>Installs both low-level hooks. False where Windows refused one; nothing is left installed then.</summary>
    public bool Start()
    {
        if (started) return true;
        hookThread.Start();
        watchThread.Start();
        hookReady.Wait(TimeSpan.FromSeconds(2));
        started = Volatile.Read(ref hookThreadId) != 0 && mouse != IntPtr.Zero && keyboard != IntPtr.Zero;
        return started;
    }

    private void Hooks()
    {
        hookThreadId = Win32.GetCurrentThreadId();
        // A low-level hook is delivered to the installing thread's message queue; the queue must exist first.
        Win32.PeekMessageW(out _, IntPtr.Zero, 0, 0, 0);
        mouseProc = MouseHook;
        keyboardProc = KeyboardHook;
        mouse = Win32.SetWindowsHookExW(Win32.WH_MOUSE_LL, mouseProc, Win32.GetModuleHandleW(null), 0);
        keyboard = Win32.SetWindowsHookExW(Win32.WH_KEYBOARD_LL, keyboardProc, Win32.GetModuleHandleW(null), 0);
        if (mouse == IntPtr.Zero || keyboard == IntPtr.Zero)
        {
            if (mouse != IntPtr.Zero) Win32.UnhookWindowsHookEx(mouse);
            if (keyboard != IntPtr.Zero) Win32.UnhookWindowsHookEx(keyboard);
            mouse = keyboard = IntPtr.Zero;
            hookThreadId = 0;
            hookReady.Set();
            return;
        }
        hookReady.Set();
        while (Win32.GetMessageW(out Win32.MSG message, IntPtr.Zero, 0, 0) > 0)
        {
            Win32.TranslateMessage(ref message);
            Win32.DispatchMessageW(ref message);
        }
    }

    private IntPtr MouseHook(int code, IntPtr wParam, IntPtr lParam)
    {
        long started = Stopwatch.GetTimestamp();
        try
        {
            if (code >= 0)
            {
                int message = (int)wParam;
                var data = Marshal.PtrToStructure<Win32.MSLLHOOKSTRUCT>(lParam);
                if (message == 0x0200) // WM_MOUSEMOVE
                    events.Add(new HoverEvent(HoverEventKind.Move, data.pt.X, data.pt.Y, Held(), Now()));
                else if (message is 0x0201 or 0x0204 or 0x0207) // buttons
                    events.Add(new HoverEvent(HoverEventKind.Button, data.pt.X, data.pt.Y, Held(), Now()));
                else if (message is 0x020A or 0x020E) // wheel
                    events.Add(new HoverEvent(HoverEventKind.Other, data.pt.X, data.pt.Y, Held(), Now()));
            }
        }
        catch (Exception) { /* an event the watcher never sees is one hover, not a crashed hook */ }
        finally
        {
            long elapsed = Stopwatch.GetTimestamp() - started;
            long seen = Interlocked.Read(ref maxHookTicks);
            while (elapsed > seen && Interlocked.CompareExchange(ref maxHookTicks, elapsed, seen) != seen)
                seen = Interlocked.Read(ref maxHookTicks);
        }
        return Win32.CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    private IntPtr KeyboardHook(int code, IntPtr wParam, IntPtr lParam)
    {
        long started = Stopwatch.GetTimestamp();
        try
        {
            if (code >= 0)
            {
                var data = Marshal.PtrToStructure<Win32.KBDLLHOOKSTRUCT>(lParam);
                int message = (int)wParam;
                bool down = message is 0x0100 or 0x0104; // WM_KEYDOWN, WM_SYSKEYDOWN
                bool up = message is 0x0101 or 0x0105;
                HoverModifier modifier = policy().Modifier;
                if (down || up)
                {
                    if (down && data.vkCode == 0x1B && escape is not null) escape();
                    bool chosen = IsModifierKey(data.vkCode, modifier);
                    if (chosen)
                        events.Add(new HoverEvent(down ? HoverEventKind.ModifierDown : HoverEventKind.ModifierUp,
                            0, 0, down, Now()));
                    else
                        events.Add(new HoverEvent(HoverEventKind.Other, 0, 0, Held(), Now()));
                }
            }
        }
        catch (Exception) { }
        finally
        {
            long elapsed = Stopwatch.GetTimestamp() - started;
            long seen = Interlocked.Read(ref maxHookTicks);
            while (elapsed > seen && Interlocked.CompareExchange(ref maxHookTicks, elapsed, seen) != seen)
                seen = Interlocked.Read(ref maxHookTicks);
        }
        return Win32.CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    /// <summary>A modifier's key: the generic virtual key and the left/right variants a low-level hook reports
    /// for a physical or injected press (VK_LCONTROL, VK_RCONTROL, and their Shift and Alt pairs).</summary>
    private static bool IsModifierKey(uint vk, HoverModifier modifier) => modifier switch
    {
        HoverModifier.Control => vk is 0x11 or 0xA2 or 0xA3,
        HoverModifier.Shift => vk is 0x10 or 0xA0 or 0xA1,
        HoverModifier.Alt => vk is 0x12 or 0xA4 or 0xA5,
        _ => vk is 0x5B or 0x5C,
    };

    private static int[] Keys(HoverModifier modifier) => modifier switch
    {
        HoverModifier.Control => [0x11],
        HoverModifier.Shift => [0x10],
        HoverModifier.Alt => [0x12],
        _ => [0x5B, 0x5C],
    };

    private bool Held() => Win32.Down(Keys(policy().Modifier));

    private static long Now() => Environment.TickCount64;

    /// <summary>The watcher's one loop: drain an event or check the rest. Reads start on the pool, never here.</summary>
    private void Watch()
    {
        while (!disposed)
        {
            HoverEvent next = default;
            bool got;
            try { got = events.TryTake(out next, 25); }
            catch (Exception) { return; }
            try
            {
                if (got) Handle(next);
                else SettleCheck();
            }
            catch (Exception error)
            {
                // A watcher thread that dies silently takes hover with it and says nothing; keep its cause.
                LastOutcome = "error:" + error.GetType().Name + ":" + error.Message;
            }
        }
    }

    private void Handle(HoverEvent next)
    {
        EventsSeen += 1;
        LastEventDelayMs = Now() - next.At;
        LastEvent = next.Kind + " held=" + next.Held;
        if (next.Kind == HoverEventKind.ModifierDown) ModifierDowns += 1;
        switch (next.Kind)
        {
            case HoverEventKind.Move:
                bool moved = lastX == int.MinValue || Math.Abs(next.X - lastX) > 2 || Math.Abs(next.Y - lastY) > 2;
                lastX = next.X;
                lastY = next.Y;
                modifierHeld = next.Held;
                if (reading && moved) CancelRead();
                if (moved)
                {
                    lastMoveAt = next.At;
                    armed = true;
                    tapped = false;
                }
                break;
            case HoverEventKind.ModifierDown:
                modifierHeld = true;
                bool chord = OtherModifierDown(policy().Modifier);
                bool completed = recogniser.Saw(policy().Gesture, true, chord, next.At);
                // Holding the key after the pointer has rested is the common way to ask: the rest starts now.
                if (!chord) { armed = true; lastMoveAt = next.At; }
                if (policy().Gesture == HoverGesture.DoubleTap && completed)
                {
                    tapped = true;
                    armed = true;
                    lastMoveAt = next.At;
                }
                break;
            case HoverEventKind.ModifierUp:
                modifierHeld = false;
                recogniser.Saw(policy().Gesture, false, false, next.At);
                // A completed double-tap is the ask, and the key is up by the time it is read; holding is over only
                // when the press did not complete the tap.
                if (policy().Gesture == HoverGesture.DoubleTap && tapped) break;
                // The hover is over: the next one may look the same word up again.
                lastWordKey = null;
                armed = false;
                CancelRead();
                break;
            case HoverEventKind.Button:
                button?.Invoke(next.X, next.Y);
                recogniser.OtherInput();
                if (reading) CancelRead();
                armed = false;
                tapped = false;
                break;
            case HoverEventKind.Other:
                recogniser.OtherInput();
                if (reading) CancelRead();
                armed = false;
                tapped = false;
                break;
        }
    }

    private static bool OtherModifierDown(HoverModifier chosen) =>
        (chosen != HoverModifier.Control && Win32.Down(0x11)) ||
        (chosen != HoverModifier.Shift && Win32.Down(0x10)) ||
        (chosen != HoverModifier.Alt && Win32.Down(0x12)) ||
        (chosen != HoverModifier.Windows && Win32.Down(0x5B, 0x5C));

    /// <summary>One rest check: the gate's cheap refusals first, then the number, then the read.</summary>
    private void SettleCheck()
    {
        SettleChecks += 1;
        if (reading || !armed) return;
        HoverPolicy current = policy();
        if (!current.Enabled) return;
        long still = Now() - lastMoveAt;
        // The current point, not the last event's: a pointer moved by a script or another process must read where it
        // is now, and a missed move must never turn into a read at a stale coordinate.
        if (Win32.GetCursorPos(out Win32.POINT cursor)) { lastX = cursor.X; lastY = cursor.Y; }
        (_, uint pid, string process) = HoverReader.WindowAt(lastX, lastY);
        LastStillMs = still;
        LastSettleMs = current.SettleMs;
        HoverVerdict verdict = current.Decide(modifierHeld, tapped, still, process, null, lastWordKey,
            reader.CaptureInFlight);
        if (!verdict.Look)
        {
            LastOutcome = "quiet:" + verdict.Refusal;
            return;
        }
        armed = false;
        tapped = false;
        reading = true;
        ReadsStarted += 1;
        LastOutcome = "reading";
        int generation = ++readGeneration;
        CaptureRequest request = begin(lastX, lastY);
        inFlightRequest = request;
        inFlight?.Dispose();
        inFlight = new CancellationTokenSource();
        CancellationToken token = inFlight.Token;
        int x = lastX, y = lastY;
        _ = Task.Run(() => ReadAsync(request, x, y, current, token, generation), CancellationToken.None);
    }

    private async Task ReadAsync(CaptureRequest request, int x, int y, HoverPolicy policy, CancellationToken token,
        int generation)
    {
        HoverRead read;
        try { read = await reader.ReadAsync(x, y, policy, token).ConfigureAwait(false); }
        catch (Exception error) { read = HoverRead.Miss("failed", 0, error.GetType().Name); }
        finally { if (Volatile.Read(ref readGeneration) == generation) reading = false; }
        LastReadMs = read.ElapsedMs;
        LastOutcome = read.Found ? "word" : "miss:" + (read.Refusal ?? "none");
        LastDiagnostics = read.Diagnostics;
        LastWord = read.Word;
        if (read.Found) WordsFound += 1;
        if (token.IsCancellationRequested || !book.IsOpen(request))
        {
            book.Cancel(request);
            return;
        }
        if (!read.Found)
        {
            book.Cancel(request);
            // A quiet refusal is ordinary; these two are the ones the reader can act on.
            if (read.Refusal is "elevated" or "ocrUnavailable") notice(read.Refusal);
            return;
        }
        HoverWord word = read.Word!;
        // The same word under the same pointer is not a second request: the first one's panel is still the answer.
        if (lastWordKey is { } key && word.Key == key && SamePlace(word))
        {
            book.Cancel(request);
            return;
        }
        lock (waiting) waiting[request.Number] = new CapturedWord(word.Key, word.Box);
        present(word, request, x, y);
    }

    private bool SamePlace(HoverWord word) =>
        word.Box is { } box && lastX >= box.X && lastX <= box.X + box.Width && lastY >= box.Y &&
        lastY <= box.Y + box.Height;

    private void CancelRead()
    {
        inFlight?.Cancel();
        if (inFlightRequest is { } request) book.Cancel(request);
        inFlightRequest = null;
        // `reading` clears when the abandoned read returns; a new one must not overlap the one still unwinding.
    }

    /// <summary>The book's terminal word on a request this watcher made: the suppression is kept only when the panel
    /// actually drew, so a failed presentation is asked again by the next rest.</summary>
    public void Ended(CaptureAcknowledgement ending)
    {
        CapturedWord? word;
        lock (waiting)
        {
            if (!waiting.Remove(ending.Request, out word)) return;
        }
        if (ending.Outcome == CaptureOutcome.Shown)
        {
            lastWordKey = word!.Key;
        }
        else if (lastWordKey == word!.Key)
        {
            lastWordKey = null;
        }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        CancelRead();
        if (hookThreadId != 0) Win32.PostThreadMessageW(hookThreadId, 0x0012, IntPtr.Zero, IntPtr.Zero);
        events.CompleteAdding();
        try { if (hookThread.IsAlive) hookThread.Join(1000); } catch (Exception) { }
        try { if (watchThread.IsAlive) watchThread.Join(1000); } catch (Exception) { }
        mouse = keyboard = IntPtr.Zero;
        reader.Dispose();
    }
}

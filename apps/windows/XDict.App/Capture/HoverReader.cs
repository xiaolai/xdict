// The word under a pointer (plan-windows-parity WS-P8, ADR-0014 decision 6): Accessibility first, then the window's
// own pixels through Windows.Media.Ocr. Every read names the one window it is of, so the word keeps its program; a
// point over one of XDict's windows reads that window completely and then the first ordinary app behind it. UIA runs
// on one dedicated STA thread (from the UI thread it crashes this process; from a pool thread it finds nothing — the
// spike measured both), and a read that stops answering is abandoned rather than waited on.
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using XDict.Models;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace XDict.App.Capture;

/// <summary>One word a point read found, and the sentence around it where the acquisition could measure one.</summary>
public sealed record HoverWord(
    string Term, string Sentence, int TermStart, int TermLength, SelectionBox? Box,
    string SourceName, uint SourceId, string Acquisition, double Confidence, string WindowKey)
{
    /// <summary>The suppression key: the same word under the same pointer is not a second request.</summary>
    public string Key => SourceId.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":" + Term;
}

/// <summary>A read's answer: a word, or why there is none. Metadata only; the sentence is never in a description.</summary>
public sealed record HoverRead(HoverWord? Word, string? Refusal, long ElapsedMs, string Diagnostics)
{
    public bool Found => Word is not null;

    public static HoverRead Miss(string refusal, long elapsed, string diagnostics = "") =>
        new(null, refusal, elapsed, diagnostics);
}

public sealed class HoverReader : IDisposable
{
    /// <summary>The top-level window and its process under a point, without reading anything: the gate's exclusion
    /// check runs before the read and pays no Accessibility call.</summary>
    public static (IntPtr Window, uint Pid, string Name) WindowAt(int x, int y)
    {
        IntPtr window = TopWindowAt(x, y);
        if (window == IntPtr.Zero) return (IntPtr.Zero, 0, "");
        Win32.GetWindowThreadProcessId(window, out uint pid);
        return (window, pid, Win32.ProcessName(pid));
    }

    /// <summary>The first top-level window, in z-order, whose box holds the point. **Never WindowFromPoint**: that
    /// sends WM_NCHITTEST and waits for the window's UI thread, and a busy UI thread (our own panel initializing its
    /// entry) makes the watcher wait with it — measured as a hover that read six seconds late on 2026-11-06. The window
    /// identity is all this read needs; UI Automation finds the element under the point itself.</summary>
    public static IntPtr TopWindowAt(int x, int y)
    {
        IntPtr found = IntPtr.Zero;
        Win32.EnumWindows((window, _) =>
        {
            if (!Win32.IsWindowVisible(window) || Win32.IsIconic(window)) return true;
            long style = (long)Win32.GetWindowLongPtrW(window, Win32.GWL_EXSTYLE);
            if ((style & Win32.WS_EX_TRANSPARENT) != 0) return true;
            if (!Win32.GetWindowRect(window, out Win32.RECT rect)) return true;
            if (rect.Right <= rect.Left || rect.Bottom <= rect.Top) return true;
            if (x < rect.Left || x >= rect.Right || y < rect.Top || y >= rect.Bottom) return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    /// <summary>The whole Accessibility read's budget. Past it the read is abandoned and the pixels are asked.</summary>
    public static readonly TimeSpan UiaDeadline = TimeSpan.FromSeconds(1.5);

    /// <summary>One capture at a time: two full-window captures at once are the deadlock the spike measured.</summary>
    public static readonly TimeSpan OcrDeadline = TimeSpan.FromSeconds(2.5);

    /// <summary>Two stuck UIA calls refuse Accessibility until one answers: an abandoned call can leave the provider
    /// unable to answer, and every later read would pay the deadline twice.</summary>
    public const int StuckLimit = 2;

    /// <summary>Whether this process runs elevated: UIPI refuses a lower process reading a higher window, never the
    /// other way, so an elevated XDict reads an elevated app normally.</summary>
    private static readonly bool SelfElevated = Win32.IsElevated((uint)Environment.ProcessId);

    private readonly UiaWorker uia = new();
    private readonly SemaphoreSlim ocrGate = new(1, 1);
    private int ocrBusy;
    private int stuck;

    /// <summary>Whether a capture is running; the gate refuses a second hover rather than starting one.</summary>
    public bool CaptureInFlight => Volatile.Read(ref ocrBusy) != 0;

    /// <summary>How many UIA reads were abandoned without an answer, for the lab's report.</summary>
    public int StuckReads => Volatile.Read(ref stuck);

    public async Task<HoverRead> ReadAsync(int x, int y, HoverPolicy policy, CancellationToken cancellation)
    {
        var watch = Stopwatch.StartNew();
        try
        {
            IntPtr window = TopWindowAt(x, y);
            if (window == IntPtr.Zero) return HoverRead.Miss("noTarget", watch.ElapsedMilliseconds);
            Win32.GetWindowThreadProcessId(window, out uint pid);
            string source = Win32.ProcessName(pid);
            bool own = pid == Environment.ProcessId;
            if (!own)
                return await ReadWindowAsync(window, pid, source, x, y, policy, watch, cancellation, scoped: false)
                    .ConfigureAwait(false);
            // **Our window is read completely before anything behind it**: its native controls, then its pixels. The
            // Debug-only fault skips that read so a test can show the behind window's word — the red-once control for
            // the own-window rule. Release builds can never take this branch.
#if DEBUG
            bool skipOwn = Environment.GetEnvironmentVariable("XDICT_HOVER_SKIP_OWN") == "1";
#else
            const bool skipOwn = false;
#endif
            HoverRead ours = skipOwn
                ? HoverRead.Miss("skipped", 0)
                : await ReadWindowAsync(window, pid, source, x, y, policy, watch, cancellation, scoped: false)
                    .ConfigureAwait(false);
            if (ours.Found) return ours;
            IntPtr behind = FirstOrdinaryBehind(window, x, y);
            if (behind == IntPtr.Zero)
                return HoverRead.Miss(ours.Refusal ?? "noWord", watch.ElapsedMilliseconds, ours.Diagnostics);
            Win32.GetWindowThreadProcessId(behind, out uint behindPid);
            HoverRead there = await ReadWindowAsync(behind, behindPid, Win32.ProcessName(behindPid), x, y, policy,
                watch, cancellation, scoped: true).ConfigureAwait(false);
            if (there.Found) return there;
            // Neither answered a word: the honest outcome names both, which is the notice's cause.
            return HoverRead.Miss("noWord", watch.ElapsedMilliseconds,
                "ours=" + (ours.Refusal ?? "miss") + "; behind=" + (there.Refusal ?? "miss"));
        }
        catch (OperationCanceledException) { return HoverRead.Miss("cancelled", watch.ElapsedMilliseconds); }
        catch (Exception error) { return HoverRead.Miss("failed", watch.ElapsedMilliseconds, error.GetType().Name); }
    }

    private async Task<HoverRead> ReadWindowAsync(IntPtr window, uint pid, string source, int x, int y,
        HoverPolicy policy, Stopwatch watch, CancellationToken cancellation, bool scoped)
    {
        if (policy.Excludes(source)) return HoverRead.Miss("excluded", watch.ElapsedMilliseconds);
        if (pid != Environment.ProcessId && Win32.IsElevated(pid) && !SelfElevated)
            return HoverRead.Miss("elevated", watch.ElapsedMilliseconds);
        cancellation.ThrowIfCancellationRequested();
        if (Volatile.Read(ref stuck) < StuckLimit)
        {
            Task<UiaAnswer> posted = uia.Post(() => ReadUia(window, x, y, scoped), cancellation);
            try
            {
                UiaAnswer answer = await posted.WaitAsync(UiaDeadline, cancellation).ConfigureAwait(false);
                if (answer.Refusal != "stuck") Interlocked.Exchange(ref stuck, 0);
                if (answer.Word is not null)
                    return new HoverRead(answer.Word with { SourceName = source, SourceId = pid },
                        null, watch.ElapsedMilliseconds, answer.Diagnostics);
            }
            catch (TimeoutException)
            {
                Interlocked.Increment(ref stuck);
                uia.Abandon();
            }
        }
        cancellation.ThrowIfCancellationRequested();
        OcrAnswer pixels = await RecognizeGuardedAsync(window, x, y, source, pid, watch, cancellation)
            .ConfigureAwait(false);
        return pixels.Word is not null
            ? new HoverRead(pixels.Word, null, watch.ElapsedMilliseconds, pixels.Diagnostics)
            : HoverRead.Miss(pixels.Refusal ?? "noWord", watch.ElapsedMilliseconds, pixels.Diagnostics);
    }

    /// <summary>One UIA read at the point: a TextPattern range's word, or the element's own accessible name where the
    /// control exposes no text. The point's element may be a child of the document, so the text pattern is searched
    /// for on the element and then on its ancestors, and the range at the point is the word's own range.</summary>
    private static UiaAnswer ReadUia(IntPtr window, int x, int y, bool scoped)
    {
        var point = new System.Windows.Point(x, y);
        try
        {
            // A window behind one of ours is read through its **own** document: a global point hit test would find the
            // window on top (ours) and read the wrong app's element.
            AutomationElement? element = scoped ? AutomationElement.FromHandle(window) : AutomationElement.FromPoint(point);
            if (element is null) return UiaAnswer.Miss("noTarget");
            // A control never names its document: a TextBlock's, button's or link's accessible name is its own text.
            // Where that label is one word, it **is** the word under the pointer — a text range's word unit over our
            // own WinUI text can return a fragment ("ru" of "run"), and the label cannot.
            bool control = element.Current.ControlType is var type &&
                (type == ControlType.Text || type == ControlType.Button || type == ControlType.MenuItem ||
                 type == ControlType.Hyperlink || type == ControlType.ListItem);
            string name = element.Current.Name ?? "";
            if (control && Usable(name) && name.IndexOfAny([' ', '\t', '\r', '\n']) < 0)
                return UiaAnswer.Hit(new HoverWord(name, "", 0, 0, ElementBox(element), "", 0, "elementTitle", 1, ""));
            TextPattern? text = scoped ? DocumentText(element) : TextOf(element) ?? TextOfAncestor(element);
            if (text is not null)
            {
                TextPatternRange at = text.RangeFromPoint(point);
                TextPatternRange word = at.Clone();
                word.ExpandToEnclosingUnit(TextUnit.Word);
                // RichEdit's (and a browser's) word unit takes the delimiter with it; the word under the pointer is
                // the word, not its trailing space. The range is trimmed so the sentence's offset stays exact.
                string term = TrimWord(word);
                if (!Usable(term)) return UiaAnswer.Miss("noWord");
                TextPatternRange paragraph = word.Clone();
                string around;
                try
                {
                    paragraph.ExpandToEnclosingUnit(TextUnit.Paragraph);
                    around = paragraph.GetText(-1);
                }
                catch (Exception error) when (error is InvalidOperationException or ElementNotAvailableException)
                {
                    paragraph = word.Clone();
                    paragraph.ExpandToEnclosingUnit(TextUnit.Line);
                    around = paragraph.GetText(-1);
                }
                int start = Offset(paragraph, word, around, term);
                // Our own WinUI text can answer a word range with a fragment of the word (the caret's prefix); the
                // provider's own segmentation is kept for every other app, where it is the better rule.
                if (element.Current.ProcessId == Environment.ProcessId && start >= 0)
                {
                    (int wordStart, int wordLength) = ManualWord(around, start);
                    if (wordLength > 0 && (wordStart != start || wordLength != term.Length))
                    {
                        term = around.Substring(wordStart, wordLength);
                        start = wordStart;
                    }
                }
                return UiaAnswer.Hit(new HoverWord(term, around, start, term.Length, UnionOf(word),
                    "", 0, "textRange", 1, ""));
            }
            if ((control || text is null) && Usable(name))
                return UiaAnswer.Hit(new HoverWord(name, "", 0, 0, ElementBox(element), "", 0, "elementTitle", 1, ""));
            // The point can land on a container above the control that holds the word (a panel's grid over its text
            // blocks). The native control under the point is still read: a Text descendant whose box holds it.
            if (text is null && ControlTextAt(element, point) is { } label)
                return UiaAnswer.Hit(new HoverWord(label.Current.Name, "", 0, 0, ElementBox(label), "", 0,
                    "elementTitle", 1, ""));
            return UiaAnswer.Miss(text is null ? "noTextPattern" : "noWord");
        }
        catch (Exception error)
        {
            // ArgumentException is a point outside the text; only an unanswered call (the deadline above) is stuck.
            string refusal = error is ElementNotAvailableException or InvalidOperationException or ArgumentException
                ? "unavailable" : "failed";
            return UiaAnswer.Miss(refusal + ":" + error.GetType().Name);
        }
    }

    /// <summary>The whole word containing `index` in `text`, expanded over letters, digits, marks and the apostrophes
    /// and hyphens inside a word. Used for XDict's own text, whose range can answer a fragment.</summary>
    private static (int Start, int Length) ManualWord(string text, int index)
    {
        if (index < 0 || index > text.Length) return (-1, 0);
        bool Word(char c) => char.IsLetterOrDigit(c) || c == '_' || c == '\'' || c == '\u2019' ||
            System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c) is
                System.Globalization.UnicodeCategory.NonSpacingMark or
                System.Globalization.UnicodeCategory.SpacingCombiningMark or
                System.Globalization.UnicodeCategory.EnclosingMark;
        int start = index, end = index;
        while (start > 0 && Word(text[start - 1])) start--;
        while (end < text.Length && Word(text[end])) end++;
        // A hyphen inside a word joins it; at either end it is punctuation.
        while (start > 0 && text[start - 1] == '-' && start >= 2 && Word(text[start - 2])) start--;
        while (end + 1 < text.Length && text[end] == '-' && Word(text[end + 1])) end++;
        return (start, end - start);
    }

    /// <summary>Whitespace at either end of an expanded word is the unit's delimiter, not part of the word.</summary>
    private static string TrimWord(TextPatternRange word)
    {
        string term = word.GetText(-1);
        for (int i = 0; i < 8 && term.Length > 0 && char.IsWhiteSpace(term[^1]); i++)
        {
            word.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, -1);
            term = word.GetText(-1);
        }
        for (int i = 0; i < 8 && term.Length > 0 && char.IsWhiteSpace(term[0]); i++)
        {
            word.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, 1);
            term = word.GetText(-1);
        }
        return term;
    }

    /// <summary>The same test the contract applies to a term, before the read costs a lookup: non-empty, no control
    /// character, at most the lookup's 200 units.</summary>
    private static bool Usable(string term) =>
        !string.IsNullOrWhiteSpace(term) && term.Length <= 200 && !term.Any(char.IsControl);

    /// <summary>The term's offset in `around`, measured by moving the paragraph's end to the word's start, or -1 where
    /// the ranges disagree (a provider that rewrites text under the read).</summary>
    private static int Offset(TextPatternRange paragraph, TextPatternRange word, string around, string term)
    {
        try
        {
            TextPatternRange before = paragraph.Clone();
            before.MoveEndpointByRange(TextPatternRangeEndpoint.End, word, TextPatternRangeEndpoint.Start);
            int start = before.GetText(-1).Length;
            if (start < 0 || start + term.Length > around.Length ||
                !string.Equals(around.Substring(start, term.Length), term, StringComparison.Ordinal)) return -1;
            return start;
        }
        catch (Exception) { return -1; }
    }

    private static TextPattern? TextOf(AutomationElement element) =>
        element.TryGetCurrentPattern(TextPattern.Pattern, out object pattern) ? (TextPattern)pattern : null;

    /// <summary>The nearest Text control whose box holds the point, among a container's descendants; the container
    /// itself may name nothing. Bounded: a large document is not walked here, and its text was already asked for.</summary>
    private static AutomationElement? ControlTextAt(AutomationElement root, System.Windows.Point point)
    {
        var condition = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text);
        int seen = 0;
        foreach (AutomationElement candidate in root.FindAll(TreeScope.Descendants, condition))
        {
            if (++seen > 256) break;
            System.Windows.Rect box = candidate.Current.BoundingRectangle;
            if (box.Contains(point) && !string.IsNullOrWhiteSpace(candidate.Current.Name)) return candidate;
        }
        return null;
    }

    /// <summary>The document inside a named window that exposes text, for a window read under another (a global point
    /// hit test would name the window on top instead).</summary>
    private static TextPattern? DocumentText(AutomationElement root)
    {
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Document));
        foreach (AutomationElement candidate in root.FindAll(TreeScope.Descendants, condition))
        {
            TextPattern? text = TextOf(candidate);
            if (text is not null) return text;
        }
        return null;
    }

    private static TextPattern? TextOfAncestor(AutomationElement element)
    {
        AutomationElement? parent;
        try { parent = TreeWalker.ControlViewWalker.GetParent(element); }
        catch (Exception) { return null; }
        for (int depth = 0; parent is not null && depth < 12; depth++)
        {
            TextPattern? text = TextOf(parent);
            if (text is not null) return text;
            try { parent = TreeWalker.ControlViewWalker.GetParent(parent); }
            catch (Exception) { return null; }
        }
        return null;
    }

    private static SelectionBox? UnionOf(TextPatternRange range)
    {
        try
        {
            var boxes = new List<SelectionBox>();
            foreach (System.Windows.Rect rectangle in range.GetBoundingRectangles())
            {
                double x = rectangle.X, y = rectangle.Y, width = rectangle.Width, height = rectangle.Height;
                if (!double.IsFinite(x) || !double.IsFinite(y) || !double.IsFinite(width) || !double.IsFinite(height))
                    continue;
                if (width <= 0 || height <= 0) continue;
                boxes.Add(new SelectionBox((int)Math.Floor(x), (int)Math.Floor(y),
                    (int)Math.Ceiling(width), (int)Math.Ceiling(height)));
            }
            if (boxes.Count == 0) return null;
            int left = boxes.Min(item => item.X), top = boxes.Min(item => item.Y);
            int right = boxes.Max(item => item.X + item.Width), bottom = boxes.Max(item => item.Y + item.Height);
            return new SelectionBox(left, top, right - left, bottom - top);
        }
        catch (Exception) { return null; }
    }

    private static SelectionBox? ElementBox(AutomationElement element)
    {
        try
        {
            System.Windows.Rect rectangle = element.Current.BoundingRectangle;
            if (!double.IsFinite(rectangle.X) || rectangle.Width <= 0 || rectangle.Height <= 0) return null;
            return new SelectionBox((int)Math.Floor(rectangle.X), (int)Math.Floor(rectangle.Y),
                (int)Math.Ceiling(rectangle.Width), (int)Math.Ceiling(rectangle.Height));
        }
        catch (Exception) { return null; }
    }

    /// <summary>The first visible, uncloaked window of another process under the point, below `ours` in the z-order
    /// (EnumWindows enumerates top-level windows top to bottom). This is the "first ordinary app behind it": our
    /// windows, tool windows and click-through overlays are not apps the reader is reading.</summary>
    private static IntPtr FirstOrdinaryBehind(IntPtr ours, int x, int y)
    {
        IntPtr found = IntPtr.Zero;
        bool passed = false;
        Win32.EnumWindows((window, _) =>
        {
            if (window == ours) { passed = true; return true; }
            if (!passed) return true;
            if (!Win32.IsWindowVisible(window) || Win32.IsIconic(window)) return true;
            long style = (long)Win32.GetWindowLongPtrW(window, Win32.GWL_EXSTYLE);
            if ((style & Win32.WS_EX_TRANSPARENT) != 0) return true;
            if (!Win32.GetWindowRect(window, out Win32.RECT rect)) return true;
            if (rect.Right <= rect.Left || rect.Bottom <= rect.Top) return true;
            if (x < rect.Left || x >= rect.Right || y < rect.Top || y >= rect.Bottom) return true;
            Win32.GetWindowThreadProcessId(window, out uint pid);
            if (pid == Environment.ProcessId) return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    /// <summary>The pixels, one capture at a time and bounded; a capture held past its deadline is reported stuck but
    /// still owns the lane until it returns, exactly as the macOS guard does.</summary>
    private async Task<OcrAnswer> RecognizeGuardedAsync(IntPtr window, int x, int y, string source, uint pid,
        Stopwatch watch, CancellationToken cancellation)
    {
        if (!await ocrGate.WaitAsync(0, cancellation).ConfigureAwait(false))
            return OcrAnswer.Miss("captureInFlight");
        Interlocked.Exchange(ref ocrBusy, 1);
        Task<OcrAnswer> task = Task.Run(() => Recognize(window, x, y, source, pid), CancellationToken.None);
        _ = task.ContinueWith(_ =>
        {
            Interlocked.Exchange(ref ocrBusy, 0);
            ocrGate.Release();
        }, TaskScheduler.Default);
        Task finished = await Task.WhenAny(task, Task.Delay(OcrDeadline, cancellation)).ConfigureAwait(false);
        if (finished != task) return OcrAnswer.Miss("captureStuck");
        return await task.ConfigureAwait(false);
    }

    private static OcrAnswer Recognize(IntPtr window, int x, int y, string source, uint pid)
    {
        if (!Win32.GetWindowRect(window, out Win32.RECT rect)) return OcrAnswer.Miss("noTarget");
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) return OcrAnswer.Miss("noTarget");
        using Bitmap? shot = Capture(window, width, height);
        if (shot is null) return OcrAnswer.Miss("captureFailed");
        OcrEngine? engine = OcrEngine.TryCreateFromUserProfileLanguages();
        if (engine is null) return OcrAnswer.Miss("ocrUnavailable");
        int maximum = (int)OcrEngine.MaxImageDimension;
        double scale = Math.Min(1d, Math.Min((double)maximum / width, (double)maximum / height));
        using Bitmap? scaled = scale < 1
            ? new Bitmap(shot, new Size(Math.Max(1, (int)(width * scale)), Math.Max(1, (int)(height * scale))))
            : null;
        try
        {
            OcrResult result = RecognizeAsync(engine, scaled ?? shot).GetAwaiter().GetResult();
            return Pick(result, x - rect.Left, y - rect.Top, scale, rect.Left, rect.Top, source, pid);
        }
        catch (Exception error) { return OcrAnswer.Miss("ocrFailed:" + error.GetType().Name); }
    }

    private static async Task<OcrResult> RecognizeAsync(OcrEngine engine, Bitmap bitmap)
    {
        using var memory = new MemoryStream();
        bitmap.Save(memory, ImageFormat.Png);
        memory.Position = 0;
        byte[] png = memory.ToArray();
        using var stream = new InMemoryRandomAccessStream();
        var writer = new DataWriter(stream.GetOutputStreamAt(0));
        writer.WriteBytes(png);
        await writer.StoreAsync();
        await writer.FlushAsync();
        writer.DetachStream();
        stream.Seek(0);
        BitmapDecoder decoder = await BitmapDecoder.CreateAsync(stream);
        using SoftwareBitmap software = await decoder.GetSoftwareBitmapAsync();
        return await engine.RecognizeAsync(software);
    }

    /// <summary>The word whose box holds the point (or is nearest within 12 px), its line as the sentence, and the
    /// word's offset in that line. All positions are physical screen pixels again.</summary>
    private static OcrAnswer Pick(OcrResult result, int x, int y, double scale, int left, int top, string source,
        uint pid)
    {
        OcrWord? best = null;
        OcrLine? line = null;
        double bestDistance = double.MaxValue;
        foreach (OcrLine candidate in result.Lines)
        {
            foreach (OcrWord word in candidate.Words)
            {
                double distance = Distance(word.BoundingRect, x * scale, y * scale);
                if (distance < bestDistance) { bestDistance = distance; best = word; line = candidate; }
            }
        }
        if (best is null || line is null || bestDistance > 12 * scale) return OcrAnswer.Miss("noWord");
        int start = line.Text.IndexOf(best.Text, StringComparison.Ordinal);
        Windows.Foundation.Rect box = best.BoundingRect;
        var measured = new SelectionBox(
            (int)Math.Round(box.X / scale) + left, (int)Math.Round(box.Y / scale) + top,
            Math.Max(1, (int)Math.Round(box.Width / scale)), Math.Max(1, (int)Math.Round(box.Height / scale)));
        return OcrAnswer.Hit(new HoverWord(best.Text, start >= 0 ? line.Text : "", start >= 0 ? start : 0,
            best.Text.Length, measured, source, pid, "recognition", 0.5, ""));
    }

    private static double Distance(Windows.Foundation.Rect rect, double x, double y)
    {
        double dx = x < rect.X ? rect.X - x : x > rect.Right ? x - rect.Right : 0;
        double dy = y < rect.Y ? rect.Y - y : y > rect.Bottom ? y - rect.Bottom : 0;
        return Math.Sqrt(dx * dx + dy * dy);
    }

    /// <summary>PrintWindow with full content: the window as composed, including the part our own window covers.
    /// A blank capture is a failure, never a black image sent to OCR as if it were the window.</summary>
    private static Bitmap? Capture(IntPtr window, int width, int height)
    {
        IntPtr screen = Win32.GetDC(IntPtr.Zero);
        if (screen == IntPtr.Zero) return null;
        IntPtr memory = Win32.CreateCompatibleDC(screen);
        if (memory == IntPtr.Zero) { Win32.ReleaseDC(IntPtr.Zero, screen); return null; }
        IntPtr bitmap = Win32.CreateCompatibleBitmap(screen, width, height);
        if (bitmap == IntPtr.Zero) { Win32.DeleteDC(memory); Win32.ReleaseDC(IntPtr.Zero, screen); return null; }
        IntPtr previous = Win32.SelectObject(memory, bitmap);
        try
        {
            if (!Win32.PrintWindow(window, memory, Win32.PW_RENDERFULLCONTENT)) return null;
            Bitmap copy = Image.FromHbitmap(bitmap);
            if (Blank(copy)) { copy.Dispose(); return null; }
            return copy;
        }
        catch (Exception) { return null; }
        finally
        {
            Win32.SelectObject(memory, previous);
            if (bitmap != IntPtr.Zero) Win32.DeleteObject(bitmap);
            if (memory != IntPtr.Zero) Win32.DeleteDC(memory);
            Win32.ReleaseDC(IntPtr.Zero, screen);
        }
    }

    /// <summary>A capture that is entirely one colour (usually black) proved nothing: some windows answer PrintWindow
    /// with an empty surface. Sampled rather than scanned whole.</summary>
    private static bool Blank(Bitmap bitmap)
    {
        Color first = bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2);
        for (int row = 1; row < 8; row++)
        for (int column = 1; column < 8; column++)
        {
            Color sample = bitmap.GetPixel(bitmap.Width * column / 8, bitmap.Height * row / 8);
            if (sample.ToArgb() != first.ToArgb()) return false;
        }
        return true;
    }

    public void Dispose()
    {
        uia.Dispose();
        ocrGate.Dispose();
    }

    private sealed record UiaAnswer(HoverWord? Word, string? Refusal, string Diagnostics)
    {
        public static UiaAnswer Hit(HoverWord word) => new(word, null, "");
        public static UiaAnswer Miss(string refusal) => new(null, refusal, "");
    }

    private sealed record OcrAnswer(HoverWord? Word, string? Refusal, string Diagnostics)
    {
        public static OcrAnswer Hit(HoverWord word) => new(word, null, "");
        public static OcrAnswer Miss(string refusal) => new(null, refusal, "");
    }

    /// <summary>One dedicated STA thread with a one-slot queue; a read that timed out is abandoned, never queued.</summary>
    private sealed class UiaWorker : IDisposable
    {
        private BlockingCollection<(Func<UiaAnswer> Read, TaskCompletionSource<UiaAnswer> Done)> queue = new(1);
        private Thread? thread;

        public Task<UiaAnswer> Post(Func<UiaAnswer> read, CancellationToken cancellation)
        {
            lock (this)
            {
                if (thread is null) Start();
                var done = new TaskCompletionSource<UiaAnswer>(TaskCreationOptions.RunContinuationsAsynchronously);
                if (!queue.TryAdd((read, done))) return Task.FromResult(UiaAnswer.Miss("busy"));
                cancellation.Register(() => done.TrySetCanceled(cancellation));
                return done.Task;
            }
        }

        private void Start()
        {
            thread = new Thread(() =>
            {
                foreach ((Func<UiaAnswer> read, TaskCompletionSource<UiaAnswer> done) in queue.GetConsumingEnumerable())
                {
                    try { done.TrySetResult(read()); }
                    catch (Exception error) { done.TrySetResult(UiaAnswer.Miss("failed:" + error.GetType().Name)); }
                }
            })
            {
                IsBackground = true,
                Name = "XDict hover UIA",
            };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }

        /// <summary>The caller stopped waiting: this thread may be inside a provider that never returns, so the next
        /// read gets a fresh one and this queue is left to finish by itself.</summary>
        public void Abandon()
        {
            lock (this)
            {
                queue.CompleteAdding();
                queue = new BlockingCollection<(Func<UiaAnswer>, TaskCompletionSource<UiaAnswer>)>(1);
                thread = null;
            }
        }

        public void Dispose()
        {
            lock (this)
            {
                queue.CompleteAdding();
                thread = null;
            }
        }
    }
}

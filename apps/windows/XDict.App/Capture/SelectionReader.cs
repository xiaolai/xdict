// The desktop-wide selection read (CONTRACT.md §9 mapping): a dedicated STA thread, one read at a time, a local
// deadline, and a stuck-call bound. From the UI thread UI Automation crashes this process; from a pool thread it finds
// nothing — the spike measured both, so the apartment is not negotiable.
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace XDict.App.Capture;

public sealed record SelectionBox(int X, int Y, int Width, int Height);

/// <summary>One read's answer: the term exactly as selected, its paragraph and range, its box, its source — or why not.</summary>
public sealed record SelectionRead(
    bool Found, string Term, string Paragraph, int TermStart, int TermLength,
    IReadOnlyList<SelectionBox> Boxes, string SourceName, uint SourceId, string? Refusal, long ElapsedMs,
    string FocusInfo = "")
{
    public static SelectionRead Failed(string refusal, long elapsed, string sourceName = "", uint sourceId = 0,
        string focusInfo = "") => new(false, "", "", 0, 0, [], sourceName, sourceId, refusal, elapsed, focusInfo);
}

public sealed class SelectionReader : IDisposable
{
    /// <summary>How long a read may take before the caller stops waiting; the worker is then abandoned.</summary>
    public static readonly TimeSpan DefaultDeadline = TimeSpan.FromSeconds(1.5);

    /// <summary>Two stuck calls refuse further reads: an abandoned call can leave the provider unable to answer.</summary>
    public const int StuckLimit = 2;

    private readonly object gate = new();
    private Worker? worker;
    private int stuck;

    public Task<SelectionRead> ReadAsync(CancellationToken cancellation)
    {
        Worker current;
        lock (gate)
        {
            if (stuck >= StuckLimit) return Task.FromResult(SelectionRead.Failed("stuck", 0));
            worker ??= new Worker();
            current = worker;
        }
        return current.Post(ReadOnce, cancellation);
    }

    /// <summary>The caller stopped waiting: the worker is wedged, so the next ask gets a fresh thread.</summary>
    public void Abandon()
    {
        lock (gate)
        {
            stuck++;
            worker = null;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            worker?.Dispose();
            worker = null;
        }
    }

    /// <summary>One read, on the worker's own STA thread.</summary>
    private static SelectionRead ReadOnce()
    {
        var watch = Stopwatch.StartNew();
        try
        {
            IntPtr window = Win32.GetForegroundWindow();
            if (window == IntPtr.Zero) return SelectionRead.Failed("noFocus", watch.ElapsedMilliseconds);
            Win32.GetWindowThreadProcessId(window, out uint processId);
            string source = Win32.ProcessName(processId);
            // UIPI's dead zone: an elevated window's text is not readable from here, and saying so is the outcome.
            if (processId != Environment.ProcessId && Win32.IsElevated(processId))
                return SelectionRead.Failed("elevated", watch.ElapsedMilliseconds, source, processId);
            AutomationElement? focused = AutomationElement.FocusedElement;
            if (focused is null) return SelectionRead.Failed("noFocus", watch.ElapsedMilliseconds, source, processId);
            string info = Describe(focused);
            TextPattern? text = TextOf(focused);
            if (text is null && AutomationElement.FromHandle(window) is { } windowElement)
            {
                // The focused element may be a tab strip or a chrome control: the document is a TextPattern descendant.
                var condition = new PropertyCondition(AutomationElement.IsTextPatternAvailableProperty, true);
                foreach (AutomationElement candidate in windowElement.FindAll(TreeScope.Descendants, condition))
                {
                    TextPattern? found = TextOf(candidate);
                    if (found is null) continue;
                    if (found.GetSelection().Length == 0) continue;
                    text = found;
                    info += " -> " + Describe(candidate);
                    break;
                }
            }
            if (text is null)
                return SelectionRead.Failed("noTextPattern", watch.ElapsedMilliseconds, source, processId, info);
            TextPatternRange[] selection = text.GetSelection();
            if (selection.Length == 0)
                return SelectionRead.Failed("noSelection", watch.ElapsedMilliseconds, source, processId, info);
            TextPatternRange range = selection[0];
            string term = range.GetText(-1);
            if (string.IsNullOrEmpty(term))
                return SelectionRead.Failed("emptySelection", watch.ElapsedMilliseconds, source, processId, info);
            TextPatternRange paragraphRange = range.Clone();
            paragraphRange.ExpandToEnclosingUnit(TextUnit.Paragraph);
            string paragraph = paragraphRange.GetText(-1);
            TextPatternRange before = paragraphRange.Clone();
            before.MoveEndpointByRange(TextPatternRangeEndpoint.End, range, TextPatternRangeEndpoint.Start);
            int termStart = before.GetText(-1).Length;
            if (termStart < 0 || termStart + term.Length > paragraph.Length ||
                !string.Equals(paragraph.Substring(termStart, term.Length), term, StringComparison.Ordinal))
                return SelectionRead.Failed("rangeMismatch", watch.ElapsedMilliseconds, source, processId, info);
            var boxes = new List<SelectionBox>();
            foreach (System.Windows.Rect rectangle in range.GetBoundingRectangles())
            {
                double x = rectangle.X, y = rectangle.Y, width = rectangle.Width, height = rectangle.Height;
                if (!double.IsFinite(x) || !double.IsFinite(y) || !double.IsFinite(width) || !double.IsFinite(height)) continue;
                if (width <= 0 || height <= 0) continue;
                boxes.Add(new SelectionBox((int)Math.Floor(x), (int)Math.Floor(y),
                    (int)Math.Ceiling(width), (int)Math.Ceiling(height)));
            }
            return new SelectionRead(true, term, paragraph, termStart, term.Length, boxes, source, processId, null,
                watch.ElapsedMilliseconds, info);
        }
        catch (Exception error)
        {
            string reason = error is ElementNotAvailableException or InvalidOperationException ? "unavailable" : "failed";
            return SelectionRead.Failed(reason + ": " + error.GetType().Name, watch.ElapsedMilliseconds);
        }
    }

    private static TextPattern? TextOf(AutomationElement element) =>
        element.TryGetCurrentPattern(TextPattern.Pattern, out object pattern) ? (TextPattern)pattern : null;

    private static string Describe(AutomationElement element)
    {
        try
        {
            string patterns = string.Join(",", element.GetSupportedPatterns().Select(item => item.ProgrammaticName));
            return $"{element.Current.ControlType.ProgrammaticName} class={element.Current.ClassName} name={element.Current.Name} patterns=[{patterns}]";
        }
        catch (Exception error) { return "undescribable: " + error.GetType().Name; }
    }

    /// <summary>One dedicated STA thread with a one-slot queue; a second ask is refused, never queued.</summary>
    private sealed class Worker : IDisposable
    {
        private readonly BlockingCollection<(Func<SelectionRead> Read, TaskCompletionSource<SelectionRead> Done)> queue = new(1);
        private readonly Thread thread;

        public Worker()
        {
            thread = new Thread(() =>
            {
                foreach ((Func<SelectionRead> read, TaskCompletionSource<SelectionRead> done) in queue.GetConsumingEnumerable())
                {
                    try { done.TrySetResult(read()); }
                    catch (Exception error) { done.TrySetException(error); }
                }
            })
            {
                IsBackground = true,
                Name = "XDict UIA reader",
            };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }

        public Task<SelectionRead> Post(Func<SelectionRead> read, CancellationToken cancellation)
        {
            var done = new TaskCompletionSource<SelectionRead>(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!queue.TryAdd((read, done)))
                return Task.FromResult(SelectionRead.Failed("busy", 0));
            cancellation.Register(() => done.TrySetCanceled(cancellation));
            return done.Task;
        }

        public void Dispose() => queue.CompleteAdding();
    }
}

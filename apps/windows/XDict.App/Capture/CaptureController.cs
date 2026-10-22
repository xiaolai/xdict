// Look up the selection from anywhere: the reader's shortcut or the tray item numbers a request, a dedicated STA read
// takes the selection exactly as selected, the contract's constructor validates it, and the non-activating panel shows
// the entry while the sentence stays in the one ephemeral session.
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml.Controls;
using XDict.Client;
using XDict.Models;

namespace XDict.App.Capture;

public sealed class CaptureController : IDisposable
{
    private readonly ServiceClient client;
    private readonly LibraryStore store;
    private readonly SearchSession session;
    private readonly Action<string, double> openInApp;
    private readonly CaptureRequests book = new();
    private readonly CaptureContextSession contexts = new();
    private readonly SelectionReader reader = new();
    private readonly Hotkey hotkey;
    private readonly TrayIcon tray;
    private CapturePanel? panel;
    private EntryPane? pane;
    private DictionaryEntrySource? source;
    private string? paneEdition;
    private string? paneFolder;
    private CancellationTokenSource? inFlight;
    private CaptureRequest? inFlightRequest;
    private Win32.HookProc? escapeHook;
    private IntPtr escape;
    private CaptureSettings settings = new();

    public CaptureController(ServiceClient client, LibraryStore store, SearchSession session, Action<string, double> openInApp)
    {
        this.client = client;
        this.store = store;
        this.session = session;
        this.openInApp = openInApp;
        hotkey = new Hotkey(() => AskGuarded(CaptureTrigger.Selection));
        tray = new TrayIcon();
        tray.LookupRequested += () => AskGuarded(CaptureTrigger.Menu);
        tray.OpenRequested += () => openInApp("", 0);
        tray.SettingsRequested += () => SettingsRequested?.Invoke();
        tray.ExitRequested += () => Microsoft.UI.Xaml.Application.Current.Exit();
        book.OnEnd(OnEnded);
    }

    public event Action? SettingsRequested;

    public CaptureSettings Settings => settings;
    public bool HotkeyRegistered => hotkey.Registered;
    public bool TrayVisible => tray.Visible;
    public CapturePanel? Panel => panel;
    public CaptureAcknowledgement? LastAcknowledgement { get; private set; }

    /// <summary>The read's refusal code, for the labs and the acceptance evidence.</summary>
    public string? LastRefusal { get; private set; }

    /// <summary>What made the last panel presentation fail; the reader sees a sentence, this keeps the cause.</summary>
    public string? LastFailure { get; private set; }

    /// <summary>What element the read found and which patterns it supports, for the acceptance evidence.</summary>
    public string LastFocusInfo { get; private set; } = "";
    public bool LastFocusUnchanged { get; private set; }
    public long LastForegroundAfterShow { get; private set; }
    public long PanelHandle => panel?.Handle.ToInt64() ?? 0;

    /// <summary>The shortcut and the tray item, or what refused them.</summary>
    public bool Start()
    {
        settings = CaptureSettings.Load();
        bool registered = hotkey.Register(settings.Modifiers, settings.Key);
        tray.Show();
        return registered;
    }

    /// <summary>A rebinding is kept only when Windows gave it; a clash leaves the old combination working.</summary>
    public CaptureSettings Rebind(uint modifiers, uint key)
    {
        settings = hotkey.Rebind(settings, modifiers, key);
        settings.Save();
        return settings;
    }

    /// <summary>The tray menu's own route, for the lab: 1 is "look up the selection".</summary>
    public void RunTrayCommand(int command)
    {
        if (command == 1) AskGuarded(CaptureTrigger.Menu);
    }

    public async Task AskAsync(CaptureTrigger trigger)
    {
        CaptureRequest request = book.BeginPresenting(trigger);
        LastRefusal = null;
        InstallEscape();
        inFlight?.Cancel(); // never disposed here: a read still unwinding may be registered on its token
        inFlight = new CancellationTokenSource();
        inFlightRequest = request;
        CancellationToken cancellation = inFlight.Token;
        SelectionRead read;
        try
        {
            // A browser's accessibility tree sleeps for exactly one read (the spike measured it): ask again once.
            read = await reader.ReadAsync(cancellation).WaitAsync(SelectionReader.DefaultDeadline, cancellation);
            if (!read.Found && (read.Refusal is "noTextPattern" or "emptySelection" ||
                read.Refusal?.StartsWith("unavailable", StringComparison.Ordinal) == true))
            {
                await Task.Delay(150, cancellation);
                read = await reader.ReadAsync(cancellation).WaitAsync(SelectionReader.DefaultDeadline, cancellation);
            }
        }
        catch (TimeoutException)
        {
            LastRefusal = "stuck";
            reader.Abandon();
            // The notice comes first: cancelling with no panel up removes the Escape hook the panel then needs.
            ShowNotice(Strings.Get("capture.stuck"));
            book.Cancel(request);
            return;
        }
        catch (OperationCanceledException)
        {
            return; // superseded or dismissed; the book has ended it
        }
        LastRefusal = read.Refusal;
        LastFocusInfo = read.FocusInfo;
        if (!read.Found)
        {
            ShowNotice(SentenceFor(read.Refusal ?? "denied"));
            book.Cancel(request);
            return;
        }
        CaptureValue.Result result = Build(read, trigger);
        CapturedTerm? term = result.Valid ? CapturedTerm.From(result) : null;
        if (term is null)
        {
            ShowNotice(Strings.Get("capture.denied"));
            book.Cancel(request);
            return;
        }
        SelectionBox? box = UnionBox(read.Boxes);
        var sink = new PanelSink(delivery => PresentGuarded(delivery, box));
        CaptureDeliveryAnswer answer = book.Deliver(term, request, sink);
        if (answer == CaptureDeliveryAnswer.Refused) return;
    }

    /// <summary>The validation input (§2-§3): the term exactly as selected, its sentence cut, its box in pixels.</summary>
    private static CaptureValue.Result Build(SelectionRead read, CaptureTrigger trigger)
    {
        SentenceCut.Sentence? sentence = SentenceCut.Around(read.Paragraph, read.TermStart, read.TermLength);
        Win32.GetCursorPos(out Win32.POINT pointer);
        var cut = new JsonArray();
        if (sentence is { CutStart: true }) cut.Add("start");
        if (sentence is { CutEnd: true }) cut.Add("end");
        JsonObject context = sentence is null
            ? new JsonObject { ["kind"] = "unavailable", ["reason"] = "notCaptured" }
            : new JsonObject
            {
                ["kind"] = "available",
                ["sentence"] = sentence.Text,
                ["term"] = new JsonObject { ["start"] = sentence.TermStart, ["length"] = sentence.TermLength },
                ["cut"] = cut,
                ["gap"] = null,
            };
        JsonObject box = read.Boxes.Count == 0
            ? new JsonObject { ["kind"] = "absent" }
            : new JsonObject
            {
                ["kind"] = "measured",
                ["quality"] = "containing",
                ["rect"] = new JsonObject
                {
                    ["x"] = read.Boxes.Min(item => item.X),
                    ["y"] = read.Boxes.Min(item => item.Y),
                    ["width"] = read.Boxes.Max(item => item.X + item.Width) - read.Boxes.Min(item => item.X),
                    ["height"] = read.Boxes.Max(item => item.Y + item.Height) - read.Boxes.Min(item => item.Y),
                },
            };
        var input = new JsonObject
        {
            ["term"] = read.Term,
            ["trigger"] = trigger switch
            {
                CaptureTrigger.Selection => "selection",
                CaptureTrigger.Menu => "menu",
                CaptureTrigger.Service => "service",
                _ => "pointerGesture",
            },
            ["acquisition"] = "textRange",
            ["confidence"] = 1,
            ["source"] = new JsonObject { ["process"] = read.SourceName, ["pid"] = read.SourceId },
            ["pointer"] = new JsonObject { ["x"] = pointer.X, ["y"] = pointer.Y },
            ["box"] = box,
            ["context"] = context,
        };
        return CaptureValue.Make(input);
    }

    private async Task PresentAsync(CaptureDelivery delivery, SelectionBox? box)
    {
        // A stale delivery (superseded, closed) shows nothing: the reader's newer gesture owns the panel.
        if (!book.IsCurrent(delivery.Request)) return;
        inFlightRequest = null;
        CapturePanel view = EnsurePanel();
        bool drawn = false;
        try
        {
            view.SetContent(delivery.Term.Term, Strings.Format("capture.searching", delivery.Term.Term));
            contexts.Hold(delivery.Term, delivery.Request.Number, delivery.Generation);
            IntPtr before = Win32.GetForegroundWindow();
            view.ShowAt(box);
            IntPtr after = Win32.GetForegroundWindow();
            LastForegroundAfterShow = after.ToInt64();
            // GetForegroundWindow can read 0 while a window is being created; the stable foreground is the claim.
            LastFocusUnchanged = after == before || after == IntPtr.Zero;
            SearchPage page = await session.LookupAsync(delivery.Term.Term, null, 0, 20);
            if (!book.IsCurrent(delivery.Request)) return;
            if (page.Hits.Count == 0)
            {
                ResetEntry();
                view.SetStatus(Strings.Format("capture.noMatch", delivery.Term.Term));
                drawn = true;
            }
            else
            {
                SearchHit hit = page.Hits[0];
                if (pane is null || paneEdition != hit.Edition)
                {
                    pane?.Dispose();
                    PaneFactory.Cleanup(paneFolder);
                    paneFolder = null;
                    view.EntryHostGrid.Children.Clear();
                    var reading = new ReadingPreferenceStore(ReadingPreferenceStore.DefaultPath);
                    PaneFactory.Built built = await PaneFactory.CreateAsync(client, hit.Edition,
                        session.Dictionaries.First(item => item.Edition == hit.Edition).Handle,
                        browser => view.EntryHostGrid.Children.Add(browser), reading);
                    // A newer delivery took over while this pane was initializing: drop it, fields and all.
                    if (!book.IsCurrent(delivery.Request))
                    {
                        built.Pane.Dispose();
                        PaneFactory.Cleanup(built.Folder);
                        // The old pane was disposed just above; the fields must not keep naming it, or a later
                        // delivery for the same edition reuses a closed view. The disposed browser leaves the grid.
                        view.EntryHostGrid.Children.Clear();
                        pane = null;
                        source = null;
                        paneEdition = null;
                        return;
                    }
                    pane = built.Pane;
                    source = built.Source;
                    paneFolder = built.Folder;
                    paneEdition = hit.Edition;
                }
                EntryResponse response = await source!.EntryAsync(hit.Entry);
                await pane!.ShowAsync(response);
                if (!book.IsCurrent(delivery.Request)) return;
                view.SetStatus(Strings.Format("search.results", page.Hits.Count));
                drawn = true;
            }
        }
        catch (ServiceFailureException error)
        {
            LastFailure = error.ErrorType + ": " + error.Message;
            // Only the delivery that still owns the panel may label it: a stale failure is not the entry on screen.
            if (book.IsCurrent(delivery.Request)) view.SetStatus(Strings.Get("capture.denied"));
        }
        catch (Exception error)
        {
            // A guard failure or a programming error is not the reader's "denied"; keep its cause for the report.
            LastFailure = error.GetType().Name + ": " + error.Message;
            if (book.IsCurrent(delivery.Request)) view.SetStatus(Strings.Get("capture.denied"));
        }
        if (drawn) Acknowledge(delivery, CaptureOutcome.Shown);
        else Acknowledge(delivery, CaptureOutcome.NotShown);
    }

    /// <summary>Drops the entry a previous capture showed; the panel's host, its binding and its private folder.</summary>
    private void ResetEntry()
    {
        pane?.Dispose();
        pane = null;
        source = null;
        paneEdition = null;
        PaneFactory.Cleanup(paneFolder);
        paneFolder = null;
        panel?.EntryHostGrid.Children.Clear();
    }

    /// <summary>The union of the selection's rectangles, physical screen pixels; null where the read measured none.</summary>
    private static SelectionBox? UnionBox(IReadOnlyList<SelectionBox> boxes)
    {
        if (boxes.Count == 0) return null;
        int left = boxes.Min(item => item.X), top = boxes.Min(item => item.Y);
        int right = boxes.Max(item => item.X + item.Width), bottom = boxes.Max(item => item.Y + item.Height);
        return new SelectionBox(left, top, right - left, bottom - top);
    }

    private void Acknowledge(CaptureDelivery delivery, CaptureOutcome outcome)
    {
        if (book.Acknowledge(delivery.Request, delivery.Generation, outcome)) LastAcknowledgement =
            new CaptureAcknowledgement(delivery.Request.Number, delivery.Generation, outcome);
    }

    private void OnEnded(CaptureAcknowledgement ending)
    {
        if (inFlightRequest is { } request && request.Number == ending.Request)
        {
            inFlight?.Cancel();
            inFlightRequest = null;
            if (ending.Outcome == CaptureOutcome.Cancelled && panel is null) RemoveEscape();
        }
    }

    private void ShowNotice(string sentence)
    {
        ResetEntry();
        CapturePanel view = EnsurePanel();
        view.SetContent(Strings.Get("capture.panelTitle"), sentence);
        Win32.GetCursorPos(out Win32.POINT point);
        view.ShowAt(new SelectionBox(point.X, point.Y, 0, 0));
    }

    private static string SentenceFor(string refusal) => refusal switch
    {
        "elevated" => Strings.Get("capture.elevated"),
        "noSelection" or "emptySelection" => Strings.Get("capture.noSelection"),
        "noTextPattern" => Strings.Get("capture.noTextPattern"),
        "stuck" => Strings.Get("capture.stuck"),
        _ => Strings.Get("capture.denied"),
    };

    private CapturePanel EnsurePanel()
    {
        if (panel is not null) return panel;
        panel = new CapturePanel();
        panel.Dismissed += OnDismissed;
        panel.OpenRequested += term => OpenGuarded(term);
        return panel;
    }

    /// <summary>Expands into the main window with the term, its dictionary and the entry's scroll position.</summary>
    private async Task OpenInAppAsync(string term)
    {
        double scroll = 0;
        try
        {
            if (pane?.View.CoreWebView2 is { } core)
            {
                string answer = await core.ExecuteScriptAsync("window.scrollY");
                if (double.TryParse(answer, System.Globalization.CultureInfo.InvariantCulture, out double y)) scroll = y;
            }
        }
        catch (Exception) { }
        if (term.Length > 0) openInApp(term, scroll);
        panel?.Dismiss();
    }

    private void OnDismissed()
    {
        book.Close();
        contexts.Clear();
        RemoveEscape();
    }

    /// <summary>Escape during a read cancels it; Escape with the panel up dismisses it. Installed at the gesture.</summary>
    private void InstallEscape()
    {
        if (escape != IntPtr.Zero) return;
        escapeHook = (code, wParam, lParam) =>
        {
            if (code >= 0 && wParam == (IntPtr)Win32.WM_KEYDOWN && Marshal.ReadInt32(lParam) == Win32.VK_ESCAPE)
            {
                if (panel is { Shown: true }) panel.Dismiss();
                else
                {
                    inFlight?.Cancel();
                    if (inFlightRequest is { } request) book.Cancel(request);
                }
                return new IntPtr(1); // the capture path consumed the Escape
            }
            return Win32.CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        };
        escape = Win32.SetWindowsHookExW(Win32.WH_KEYBOARD_LL, escapeHook, Win32.GetModuleHandleW(null), 0);
    }

    private void RemoveEscape()
    {
        if (escape == IntPtr.Zero) return;
        Win32.UnhookWindowsHookEx(escape);
        escape = IntPtr.Zero;
    }

    private async void AskGuarded(CaptureTrigger trigger)
    {
        try { await AskAsync(trigger); }
        catch (Exception error) { LastFailure = error.GetType().Name + ": " + error.Message; }
    }

    private async void PresentGuarded(CaptureDelivery delivery, SelectionBox? box)
    {
        try { await PresentAsync(delivery, box); }
        catch (Exception error) { LastFailure = error.GetType().Name + ": " + error.Message; }
    }

    private async void OpenGuarded(string term)
    {
        try { await OpenInAppAsync(term); }
        catch (Exception error) { LastFailure = error.GetType().Name + ": " + error.Message; }
    }

    public void Dispose()
    {
        // A panel still up owns a window and a low-level hook; nulling the field alone left both until exit.
        panel?.Dismiss();
        RemoveEscape();
        inFlight?.Cancel();
        inFlight?.Dispose();
        pane?.Dispose();
        hotkey.Dispose();
        tray.Dispose();
        reader.Dispose();
        panel = null;
    }

    private sealed class PanelSink(Action<CaptureDelivery> present) : ICaptureSink
    {
        public CaptureDeliveryAnswer Deliver(CaptureDelivery delivery)
        {
            present(delivery);
            return CaptureDeliveryAnswer.Accepted;
        }
    }
}

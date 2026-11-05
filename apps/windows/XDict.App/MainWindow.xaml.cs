// The main window: search the library's dictionaries, read an entry, and walk the trail.
using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using XDict.Client;
using XDict.Contract;
using XDict.Models;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.SpeechSynthesis;
using Windows.Storage.Streams;
using Windows.System;

namespace XDict.App;

public sealed partial class MainWindow : Window
{
    private readonly LaunchProbe? probe = LaunchProbe.FromCommandLine();
    private ServiceClient? client;
    private LibraryStore? store;
    private SearchSession? session;
    private PaneLease paneLease = new();
    private readonly List<EntryTab> tabs = [];
    private RequestGeneration? searchGeneration;
    private IReadOnlyList<SearchHit> hits = [];
    private JsonElement? currentEntry;
    private string? currentDict;
    private string? currentHeadword;
    private readonly SemaphoreSlim showGate = new(1, 1);
    private SettingsWindow? settingsWindow;
    private ReviewWindow? reviewWindow;
    private HistoryWindow? historyWindow;
    private ExploreWindow? exploreWindow;
    private readonly TaskCompletionSource windowLoaded = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private MediaPlayer? player;
    private readonly Trail trail = new();
    private readonly ReadingPreferenceStore readingPreferences = new(ReadingPreferenceStore.DefaultPath);
    private Capture.CaptureController? capture;
    private ReviewReminders? reminders;
    private bool quitting;
    // The review UIA lab: erase the learning store, write one note so a card is due, and open the review window.
    private readonly bool reviewLab = Environment.GetCommandLineArgs().Contains("--review-lab");

    /// <summary>One tab's entry: its own WebView2, pane lease and the entry it shows. Switching tabs touches none of
    /// another tab's state; the window's current entry fields follow the selected tab.</summary>
    private sealed class EntryTab
    {
        public required TabViewItem Item { get; init; }
        public required Grid Host { get; init; }
        public PaneLease Lease { get; } = new();
        public JsonElement? Entry { get; set; }
        public string? Dict { get; set; }
        public string? Headword { get; set; }
        /// <summary>The All page's one pane per dictionary, each with its own lease; empty for a single entry.</summary>
        public List<PaneLease> ExtraLeases { get; } = [];
        /// <summary>The All page's column, and the word it was built for; null for a single entry.</summary>
        public StackPanel? AllStack { get; set; }
        public string? AllWord { get; set; }
    }

    /// <summary>What one All page pane answers for: its dictionary, its entry and its own WebView.</summary>
    private sealed record PaneContext(string Dict, JsonElement Entry, string? Headword, EntryPane Pane);

    private EntryTab? ActiveTab
    {
        get
        {
            TabViewItem? selected = Tabs.SelectedItem as TabViewItem;
            return selected is null ? null : tabs.FirstOrDefault(tab => tab.Item == selected);
        }
    }

    /// <summary>The pane find searches: the tab's own, or the first frame of an All page.</summary>
    private EntryPane? ActivePane =>
        paneLease.Pane ?? ActiveTab?.ExtraLeases.Select(lease => lease.Pane).FirstOrDefault(pane => pane is not null);

    public MainWindow()
    {
        InitializeComponent();
        App.CurrentRoot = Root;
        ThemeApplier.Apply(Root, AppSettings.Load().Theme);
        Title = Strings.Get("app.title");
        LibraryButton.Content = Strings.Get("settings.title");
        ExploreButton.Content = Strings.Get("explore.title");
        BackButton.Content = Strings.Get("search.back");
        ForwardButton.Content = Strings.Get("search.forward");
        ReturnButton.Content = Strings.Get("search.return");
        FindBox.PlaceholderText = Strings.Get("find.placeholder");
        FindPrevious.Content = Strings.Get("find.previous");
        FindNext.Content = Strings.Get("find.next");
        FindClose.Content = Strings.Get("find.close");
        AutomationProperties.SetName(FindBox, Strings.Get("find.placeholder"));
        AutomationProperties.SetName(FindPrevious, Strings.Get("find.previous"));
        AutomationProperties.SetName(FindNext, Strings.Get("find.next"));
        AutomationProperties.SetName(FindClose, Strings.Get("find.close"));
        SearchBox.PlaceholderText = Strings.Get("search.placeholder");
        AutomationProperties.SetName(SearchBox, Strings.Get("search.query"));
        AutomationProperties.SetName(ScopeBox, Strings.Get("search.scope"));
        AutomationProperties.SetName(Results, Strings.Get("search.resultsList"));
        AutomationProperties.SetName(BackButton, Strings.Get("search.back"));
        AutomationProperties.SetName(ForwardButton, Strings.Get("search.forward"));
        AutomationProperties.SetName(ReturnButton, Strings.Get("search.return"));
        AutomationProperties.SetName(LibraryButton, Strings.Get("settings.title"));
        AutomationProperties.SetName(ExploreButton, Strings.Get("explore.title"));
        UpdateTrail();
        StatusText.Text = Strings.Get("app.starting");
        // The tray owns the process: closing the main window hides it, so the shortcut, the tray and the review
        // window keep working. Quit is the tray's Exit item, a second launch's activation, or the launch harness.
        Root.Loaded += (_, _) => windowLoaded.TrySetResult();
        AppWindow.Closing += OnMainWindowClosing;
        // The client outlives this window: a Settings window can still be open and uses it; the process exit closes it.
        Closed += (_, _) => { capture?.Dispose(); capture = null; CloseAllTabs(); };
        _ = StartAsync();
    }

    private async Task StartAsync()
    {
        try
        {
            (ServiceClient started, Versions versions) = await Task.Run(() =>
            {
                // A lab may need longer than the reader's deadlines: large imports and opening 24 dictionaries at once.
                var options = new ServiceClientOptions();
#if DEBUG
                int deadlineFlag = Array.IndexOf(Environment.GetCommandLineArgs(), "--client-deadline");
                if (deadlineFlag >= 0 && deadlineFlag + 1 < Environment.GetCommandLineArgs().Length &&
                    double.TryParse(Environment.GetCommandLineArgs()[deadlineFlag + 1],
                        System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture,
                        out double seconds) && seconds > 0)
                    options = options with { LookupDeadline = TimeSpan.FromSeconds(seconds), BulkDeadline = TimeSpan.FromSeconds(Math.Max(seconds, 120)) };
#endif
                var service = new ServiceClient(Path.Combine(AppContext.BaseDirectory, "XDictService.exe"), options);
                return (service, service.Handshake());
            });
            client = started;
            StatusText.Text = Strings.Get("app.ready");
            probe?.RecordVersions(versions, started.ProcessId);
#if DEBUG
            if (await RunLabAsync(started))
            {
                started.Dispose();
                Application.Current.Exit();
                return;
            }
#endif
            await SetupSearchAsync(started);
            if (reviewLab) await PrepareReviewLabAsync();
            else if (probe is null) await FirstRunDisclosureAsync();
        }
        catch (LibraryUnreadableException error)
        {
            StatusText.Text = Strings.Format("library.unreadable", error.Message);
            TraceFailure("library: " + error.Message);
        }
        catch (ServiceFailureException error)
        {
            StatusText.Text = ServiceMessages.For(error.ErrorType);
            probe?.RecordError(error.ErrorType);
            TraceFailure("service: " + error.ErrorType + " " + error.Message);
        }
        catch (Exception error)
        {
            StatusText.Text = Strings.Get("app.serviceFailed") + " " + error.Message;
            probe?.RecordError(error.GetType().Name + ": " + error.Message);
            TraceFailure(error.GetType().Name + ": " + error.Message + "\n" + error.StackTrace);
        }

        if (probe is not null)
            await WatchQuitAsync();
    }

#if DEBUG
    /// <summary>The developer labs: one mode per run and the caller exits; false when no lab was named.</summary>
    private async Task<bool> RunLabAsync(ServiceClient started)
    {
                string[] arguments = Environment.GetCommandLineArgs();
                int captureLab = Array.IndexOf(arguments, "--capture-lab");
                if (captureLab >= 0 && captureLab + 1 < arguments.Length)
                {
                    await Capture.CaptureLab.RunAsync(arguments[captureLab + 1], started);
                    return true;
                }
                int libraryLab = Array.IndexOf(arguments, "--library-lab");
                if (libraryLab >= 0 && libraryLab + 1 < arguments.Length)
                {
                    using JsonDocument config = JsonDocument.Parse(await File.ReadAllTextAsync(arguments[libraryLab + 1]));
                    string output = config.RootElement.GetProperty("output").GetString()!;
                    string libraryPath = config.RootElement.GetProperty("library").GetString()!;
                    string[] paths = config.RootElement.GetProperty("paths").EnumerateArray()
                        .Select(path => path.GetString()!).ToArray();
                    LibraryStore labStore = LibraryStore.Load(libraryPath);
                    var window = new LibraryWindow(labStore, started, askLanguages: false);
                    await window.AddPathsAsync(paths);
                    await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new
                    {
                        count = labStore.Dictionaries.Count,
                        editions = labStore.Dictionaries.Select(item => item.Edition).ToArray(),
                        status = window.StatusText,
                    }));
                    return true;
                }
                int measureLab = Array.IndexOf(arguments, "--measure-lab");
                if (measureLab >= 0 && measureLab + 1 < arguments.Length)
                {
                    // In-app measurement: the UIA provider wedges under a long query loop, so the production search is
                    // timed where it runs — submit, results applied, and the dispatcher's next turn (the first paint).
                    using JsonDocument config = JsonDocument.Parse(await File.ReadAllTextAsync(arguments[measureLab + 1]));
                    string output = config.RootElement.GetProperty("output").GetString()!;
                    string libraryPath = config.RootElement.GetProperty("library").GetString()!;
                    string mode = config.RootElement.GetProperty("mode").GetString()!;
                    int count = config.RootElement.GetProperty("count").GetInt32();
                    string[] queries = config.RootElement.GetProperty("queries").EnumerateArray()
                        .Select(item => item.GetString()!).ToArray();
                    store = LibraryStore.Load(libraryPath);
                    session = new SearchSession(started);
                    long openStarted = Environment.TickCount64;
                    await session.OpenAsync(store.Dictionaries);
                    long openMs = Environment.TickCount64 - openStarted;
                    if (mode == "memory")
                    {
                        long serviceMb = -1;
                        try { serviceMb = System.Diagnostics.Process.GetProcessById(started.ProcessId).WorkingSet64 / (1024 * 1024); }
                        catch (Exception) { }
                        await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new
                        {
                            mode, openMs, dictionaries = session.Dictionaries.Count,
                            appMb = Environment.WorkingSet / (1024 * 1024), serviceMb,
                        }));
                        return true;
                    }
                    var samples = new List<object>();
                    for (int i = 0; i < count; i++)
                    {
                        string query = queries[i % queries.Length];
                        SearchBox.Text = query;
                        var watch = System.Diagnostics.Stopwatch.StartNew();
                        await SearchAsync(query);
                        var drawn = new TaskCompletionSource();
                        DispatcherQueue.TryEnqueue(() => drawn.TrySetResult());
                        await drawn.Task;
                        watch.Stop();
                        samples.Add(new { query, ms = watch.Elapsed.TotalMilliseconds, rows = hits.Count });
                    }
                    await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new
                    {
                        mode, openMs, dictionaries = session.Dictionaries.Count, samples,
                    }));
                    return true;
                }
                int soundLinkLab = Array.IndexOf(arguments, "--sound-link-lab");
                if (soundLinkLab >= 0 && soundLinkLab + 1 < arguments.Length)
                {
                    void Trace(string step) => File.AppendAllText(Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDict", "lab-trace.txt"),
                        DateTime.Now.ToString("HH:mm:ss.fff") + " " + step + "\n");
                    Trace("start");
                    using JsonDocument config = JsonDocument.Parse(await File.ReadAllTextAsync(arguments[soundLinkLab + 1]));
                    string output = config.RootElement.GetProperty("output").GetString()!;
                    string fixtures = config.RootElement.GetProperty("fixtures").GetString()!;
                    Trace("importing");
                    LibraryDictionary record = await LibraryImporter.ImportAsync(started,
                        PackageFinder.Discover(Path.Combine(fixtures, "sounds", "sounds.mdx")));
                    Trace("imported");
                    string dict = await LibraryInspector.OpenAsync(started, record);
                    Trace("opened");
                    Reply page;
                    try
                    {
                        page = await started.CallAsync("lookup", new { query = "sounds", dicts = new[] { dict },
                            options = new { limit = 10, offset = 0, mode = "reader", generation = (uint?)null } });
                    }
                    catch (Exception error)
                    {
                        Trace("lookup threw: " + error.GetType().Name + ": " + error.Message);
                        throw;
                    }
                    Trace("lookup: " + (page.Error is { } failure ? failure.GetRawText() : "ok"));
                    JsonElement entry = page.Ok!.Value.GetProperty("hits")[0].GetProperty("entry").Clone();
                    Trace("entry");
                    var links = new List<object>();
                    var resources = new List<object>();
                    foreach (string url in new[] { "sound://here.mp3", "sound://present.spx", "sound://gone.mp3" })
                    {
                        Trace("link request " + url);
                        Reply link = await started.CallAsync("link", new
                        {
                            dict, url, origin = new { type = "entry", entry },
                            view = new { baseUrl = "https://xdict.local/", maxBodyBytes = 1 << 20 },
                        });
                        Trace("link: " + (link.Error is { } linkError ? linkError.GetRawText() : "ok"));
                        JsonElement answer = link.Ok!.Value;
                        string type = answer.GetProperty("type").GetString()!;
                        string? path = type == "sound" ? answer.GetProperty("path").GetString() : null;
                        links.Add(new { url, type, path });
                        if (path is null) continue;
                        Trace("resource request " + path);
                        Reply resource = await started.CallAsync("resource", new
                        {
                            dict, path,
                            view = new { baseUrl = "https://xdict.local/", maxBodyBytes = 1 << 20 },
                        });
                        Trace("resource: " + (resource.Error is { } resourceError ? resourceError.GetRawText() : "ok"));
                        JsonElement ok = resource.Ok!.Value;
                        bool found = ok.GetProperty("type").GetString() == "found";
                        string? mime = found ? ok.GetProperty("mime").GetString() : null;
                        SoundChoice choice = SoundSupport.Classify(path, found, mime);
                        resources.Add(new { path, found, mime, kind = choice.Kind.ToString() });
                    }
                    Trace("writing");
                    await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new { links, resources }));
                    Trace("written");
                    return true;
                }
                int soundLab = Array.IndexOf(arguments, "--sound-lab");
                if (soundLab >= 0 && soundLab + 1 < arguments.Length)
                {
                    await SoundLab.RunAsync(arguments[soundLab + 1]);
                    return true;
                }
                int trailLab = Array.IndexOf(arguments, "--trail-lab");
                if (trailLab >= 0 && trailLab + 1 < arguments.Length)
                {
                    using JsonDocument config = JsonDocument.Parse(await File.ReadAllTextAsync(arguments[trailLab + 1]));
                    string output = config.RootElement.GetProperty("output").GetString()!;
                    string libraryPath = config.RootElement.GetProperty("library").GetString()!;
                    store = LibraryStore.Load(libraryPath);
                    session = new SearchSession(started);
                    await session.OpenAsync(store.Dictionaries);
                    await SearchAsync("run");
                    int runRows = hits.Count;
                    bool openedFirst = false, firstBack = false;
                    if (hits.Count > 0)
                    {
                        await ShowAsync(hits[0].Edition, hits[0].Entry, "run", record: true);
                        openedFirst = true;
                        firstBack = trail.CanBack;
                    }
                    await SearchAsync("cafe");
                    int cafeRows = hits.Count;
                    bool openedSecond = false, secondBack = false, afterBack = false;
                    if (hits.Count > 0)
                    {
                        await ShowAsync(hits[0].Edition, hits[0].Entry, "cafe", record: true);
                        openedSecond = true;
                        secondBack = trail.CanBack;
                        if (trail.Back() is not null)
                        {
                            await RestoreAsync();
                            afterBack = trail.CanBack;
                        }
                    }
                    await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new
                    {
                        runRows, cafeRows, openedFirst, openedSecond, firstBack, secondBack, afterBack,
                    }));
                    return true;
                }
                int searchLab = Array.IndexOf(arguments, "--search-lab");
                if (searchLab >= 0 && searchLab + 1 < arguments.Length)
                {
                    using JsonDocument config = JsonDocument.Parse(await File.ReadAllTextAsync(arguments[searchLab + 1]));
                    string output = config.RootElement.GetProperty("output").GetString()!;
                    string libraryPath = config.RootElement.GetProperty("library").GetString()!;
                    string query = config.RootElement.GetProperty("query").GetString()!;
                    store = LibraryStore.Load(libraryPath);
                    session = new SearchSession(started);
                    await session.OpenAsync(store.Dictionaries);
                    await SearchAsync(query);
                    await File.WriteAllTextAsync(output, JsonSerializer.Serialize(new
                    {
                        hits = hits.Count,
                        first = hits.Count > 0 ? hits[0].Headword : null,
                        status = StatusText.Text,
                    }));
                    return true;
                }
                int lab = Array.IndexOf(arguments, "--entry-lab");
                if (lab >= 0 && lab + 1 < arguments.Length)
                {
                    EntryTab labTab = NewTab("lab");
                    var browser = new Microsoft.UI.Xaml.Controls.WebView2();
                    labTab.Host.Children.Add(browser);
                    await EntryLab.RunAsync(browser, arguments[lab + 1], started);
                    return true;
                }
        return false;
    }
#endif

    /// <summary>A lab's failure is otherwise silent: a windowed app has no console, and the harness sees no result.</summary>
    private static void TraceFailure(string text)
    {
#if DEBUG
        try
        {
            File.AppendAllText(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDict", "lab-trace.txt"),
                DateTime.Now.ToString("HH:mm:ss.fff") + " FAILED " + text + "\n");
        }
        catch (Exception) { }
#endif
    }

    private async Task SetupSearchAsync(ServiceClient started)
    {
        store = LibraryStore.Load();
        session = new SearchSession(started);
        IReadOnlyList<OpenOutcome> outcomes = await session.OpenAsync(store.Dictionaries);
        ScopeBox.Items.Clear();
        ScopeBox.Items.Add(Strings.Get("search.all"));
        foreach (OpenDictionary dictionary in session.Dictionaries) ScopeBox.Items.Add(dictionary.Name);
        if (ScopeBox.Items.Count > 0) ScopeBox.SelectedIndex = 0;
        string unavailable = string.Join(", ", outcomes.Where(item => item.State != OpenOutcome.Ready)
            .Select(item => item.Name + " (" + item.State + ")"));
        // Capture runs whether or not a dictionary is ready: the shortcut and the tray belong to the reader.
        capture = new Capture.CaptureController(started, store, session,
            (term, scroll) => _ = GuardAsync(() => OpenFromTrayAsync(term, scroll)));
        capture.SettingsRequested += () => OpenSettings(this, new RoutedEventArgs());
        capture.ReviewRequested += OpenReview;
        capture.HistoryRequested += OpenHistory;
        capture.MeaningRequested += OpenMeaning;
        capture.ExitRequested += Quit;
        reminders = new ReviewReminders(started, OpenReview);
        reminders.Start();
        // A refused shortcut or tray is said, and stays said: the ready sentence used to overwrite it at once.
        string captureNotice = !capture.Start() ? Strings.Get("capture.hotkeyTaken")
            : !capture.TrayVisible ? Strings.Get("capture.trayRefused") : "";
        string Join(string sentence) => captureNotice.Length == 0 ? sentence : captureNotice + " " + sentence;
        if (session.Dictionaries.Count == 0)
        {
            StatusText.Text = Join(unavailable.Length == 0
                ? Strings.Get("search.noDictionaries")
                : Strings.Get("search.noDictionaries") + " " + unavailable);
            return;
        }
        StatusText.Text = Join(unavailable.Length == 0 ? Strings.Get("app.ready") : unavailable);
        SearchBox.Focus(FocusState.Programmatic);
    }

    /// <summary>The panel's "Open in XDict": the term searched here, the first hit shown, in this window.</summary>
    public async Task LookupFromCaptureAsync(string term, double scroll = 0)
    {
        Activate();
        if (term.Length == 0) return;
        SearchBox.Text = term;
        await SearchAsync(term);
        if (hits.Count == 0) return;
        await ShowAsync(hits[0].Edition, hits[0].Entry, term, record: true, newTab: true);
        // The panel's own position is kept: the reader is looking at the same entry, not a fresh one.
        if (scroll > 0 && paneLease.Pane?.View.CoreWebView2 is { } core)
            await core.ExecuteScriptAsync("window.scrollTo(0," + scroll.ToString(System.Globalization.CultureInfo.InvariantCulture) + ")");
    }

    private string? SelectedEdition()
    {
        int index = ScopeBox.SelectedIndex;
        if (session is null || index <= 0) return null;
        List<OpenDictionary> dictionaries = session.Dictionaries.ToList();
        return index - 1 < dictionaries.Count ? dictionaries[index - 1].Edition : null;
    }

    private async Task SearchAsync(string query)
    {
        if (session is null || client is null) return;
        searchGeneration = client.NewGeneration("search");
        RequestGeneration generation = searchGeneration;
        var collected = new List<SearchHit>();
        hits = [];
        Results.ItemsSource = null;
        try
        {
            var gate = new object();
            IReadOnlyList<SearchPage> pages = await session.LookupEachAsync(query, SelectedEdition(), 50, page =>
            {
                if (searchGeneration != generation) return;
                lock (gate) collected.AddRange(page.Hits);
            }, generation);
            if (searchGeneration != generation) return;
            // The hits are applied before this method returns; the visual update is queued.
            lock (gate) hits = collected.ToList();
            string? state = pages.Select(page => page.Unavailable).FirstOrDefault(item => item is not null);
            int count = hits.Count;
            DispatcherQueue.TryEnqueue(() =>
            {
                if (searchGeneration != generation) return;
                Results.ItemsSource = hits.Select(hit => hit.Headword + " — " + hit.Dictionary + " · " + hit.How).ToList();
                Results.SelectedIndex = -1; // a new page starts unselected, so choosing its first row is a change
                StatusText.Text = count == 0
                    ? StateSentence(state ?? "noMatch")
                    : Strings.Format("search.results", count);
            });
        }
        catch (OperationCanceledException)
        {
            // A newer query superseded this one; its results are never shown.
        }
    }

    private static string StateSentence(string state) => Strings.Get(state switch
    {
        OpenOutcome.NeedsImport => "search.needsImport",
        OpenOutcome.Missing => "search.missing",
        OpenOutcome.Malformed => "search.malformed",
        OpenOutcome.Unsupported => "search.unsupported",
        OpenOutcome.Unavailable => "search.unavailable",
        _ => "search.noMatch",
    });

    private async void OnQuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        string query = (args.QueryText ?? sender.Text).Trim();
        if (query.Length > 0) await GuardAsync(() => SearchAsync(query));
    }

    private async void OnSearchTextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput || session is null) return;
        string text = sender.Text.Trim();
        if (text.Length == 0)
        {
            sender.ItemsSource = null;
            return;
        }
        string asked = text;
        RequestGeneration? generation = client?.NewGeneration("suggest");
        await GuardAsync(async () =>
        {
            // A slower earlier keystroke must not overwrite newer suggestions, or repopulate a changed box.
            var values = (await session.SuggestAsync(asked, SelectedEdition(), 10, generation)).ToList();
            if (sender.Text.Trim() == asked) sender.ItemsSource = values;
        });
    }

    private void OnSuggestionChosen(AutoSuggestBox sender, AutoSuggestBoxSuggestionChosenEventArgs args)
    {
        if (args.SelectedItem is string value) sender.Text = value;
    }

    private async void OnScopeChanged(object sender, SelectionChangedEventArgs e)
    {
        string query = SearchBox.Text.Trim();
        if (query.Length > 0) await GuardAsync(() => SearchAsync(query));
    }

    private async void OnResultSelected(object sender, SelectionChangedEventArgs e) => await GuardAsync(ShowSelectedAsync);

    private async void OnResultsKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter && Results.SelectedIndex >= 0)
        {
            e.Handled = true;
            await GuardAsync(ShowSelectedAsync);
        }
    }

    private async Task ShowSelectedAsync()
    {
        int index = Results.SelectedIndex;
        if (index < 0 || index >= hits.Count) return;
        SearchHit hit = hits[index];
        // Scope All is the All page (parity P15): the word in every dictionary that has it, one pane each. A chosen
        // dictionary keeps the one-entry tab.
        if (ScopeBox.SelectedIndex == 0)
        {
            await ShowAllAsync(hit, SearchBox.Text);
            return;
        }
        await ShowAsync(hit.Edition, hit.Entry, SearchBox.Text, record: true, newTab: true);
    }

    /// <summary>
    /// The All page: the selected word from every open dictionary that has it, each its own WebView2, pane folder,
    /// scheme and policy, in one vertical scroller. A dictionary with no hit contributes nothing; a lookup failure
    /// skips that dictionary rather than failing the page. Its panes answer their own links and sounds.
    /// </summary>
    private async Task ShowAllAsync(SearchHit seed, string query)
    {
        if (client is null || session is null) return;
        EntryTab? existing = tabs.FirstOrDefault(tab => tab.AllWord == seed.Headword);
        if (existing is not null)
        {
            Tabs.SelectedItem = existing.Item;
            ActivateTab(existing);
            return;
        }
        await showGate.WaitAsync();
        bool complete = false;
        try
        {
            EntryTab tab = NewAllTab(seed.Headword);
            Tabs.SelectedItem = tab.Item;
            StatusText.Text = Strings.Get("search.allLoading");
            int shown = 0;
            int failed = 0;
            RequestGeneration generation = client.NewGeneration("all");
            foreach (OpenDictionary dictionary in session.Dictionaries.ToList())
            {
                var section = new StackPanel { Spacing = Tokens.Space.Xs };
                PaneLease? lease = null;
                try
                {
                    var found = new List<SearchHit>();
                    await session.LookupEachAsync(seed.Headword, dictionary.Edition, 20, page =>
                    {
                        lock (found) found.AddRange(page.Hits);
                    }, generation);
                    if (!tabs.Contains(tab)) return;
                    SearchHit? hit = found.FirstOrDefault(item =>
                        item.Entry.TryGetProperty("key", out JsonElement key) && key.GetString() == seed.Headword)
                        ?? found.FirstOrDefault();
                    if (hit is null) continue;
                    section.Children.Add(new TextBlock
                    {
                        Text = dictionary.Name,
                        FontSize = Tokens.Text.Callout,
                    });
                    tab.AllStack!.Children.Add(section);
                    lease = new PaneLease();
                    var (pane, source, _) = await lease.EnsureAsync(client, dictionary.Edition, dictionary.Handle,
                        view => section.Children.Add(view), readingPreferences);
                    var context = new PaneContext(dictionary.Handle, hit.Entry.Clone(), hit.Headword, pane);
                    pane.Message += message => _ = GuardAsync(() => OnAllPaneMessageAsync(message, context));
                    pane.Failure += OnPaneFailure;
                    EntryResponse response = await source.EntryAsync(hit.Entry);
                    await pane.ShowAsync(response);
                    if (!tabs.Contains(tab))
                    {
                        lease.Reset();
                        return;
                    }
                    tab.ExtraLeases.Add(lease);
                    shown++;
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (Exception error)
                {
                    // One dictionary that cannot answer leaves the other frames standing; the page says how many.
                    failed++;
                    lease?.Reset();
                    tab.AllStack?.Children.Remove(section);
                    TraceFailure("all page, " + dictionary.Edition + ": " + error.Message);
                }
            }
            OpenDictionary seedDictionary = session.Dictionaries.First(item => item.Edition == seed.Edition);
            tab.Entry = seed.Entry.Clone();
            tab.Dict = seedDictionary.Handle;
            tab.Headword = seed.Headword;
            ActivateTab(tab);
            StatusText.Text = failed == 0
                ? Strings.Format("search.allShown", shown)
                : Strings.Format("search.allShownFailed", shown, failed);
            complete = true;
        }
        finally
        {
            showGate.Release();
        }
        if (!complete) return;
        trail.Push(new Visit(seed.Edition, seed.Entry.Clone(), query));
        UpdateTrail();
    }

    private EntryTab NewAllTab(string title)
    {
        var stack = new StackPanel
        {
            Spacing = Tokens.Space.L,
            Padding = new Thickness(Tokens.Space.M),
        };
        var host = new Grid();
        host.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = stack,
        });
        var item = new TabViewItem { Header = title, Content = host, IsClosable = true };
        var tab = new EntryTab { Item = item, Host = host, AllStack = stack, AllWord = title };
        tabs.Add(tab);
        Tabs.TabItems.Add(item);
        Tabs.SelectedItem = item;
        ActivateTab(tab);
        return tab;
    }

    private async Task OnAllPaneMessageAsync(EntryBridgeMessage message, PaneContext context)
    {
        if (message.Kind == "word" && !string.IsNullOrWhiteSpace(message.Value))
        {
            SearchBox.Text = message.Value;
            await SearchAsync(message.Value);
            return;
        }
        if (message.Kind is "link" or "sound" && !string.IsNullOrWhiteSpace(message.Value))
            await FollowLinkAsync(message.Value, context);
    }

    private async Task ShowAsync(string edition, JsonElement entry, string query, bool record, bool newTab = false)
    {
        if (client is null || session is null) return;
        OpenDictionary dictionary = session.Dictionaries.First(item => item.Edition == edition);
        // One entry display at a time: a second selection while the first is still initializing would dispose a
        // half-built pane and let the first initialization continue on a closed view.
        await showGate.WaitAsync();
        try
        {
            if (newTab && SelectOpen(entry)) return;
            EntryTab target = newTab || ActiveTab is null ? NewTab(query) : ActiveTab!;
            Tabs.SelectedItem = target.Item;
            // The handle changes when the session closes and reopens a dictionary; the old pane still sends it.
            bool rebuilt = !target.Lease.Matches(edition, dictionary.Handle);
            if (rebuilt) target.Host.Children.Clear();
            var (pane, source, built) = await target.Lease.EnsureAsync(client, edition, dictionary.Handle,
                view => target.Host.Children.Add(view), readingPreferences);
            if (built)
            {
                pane.Message += OnPaneMessage;
                pane.Failure += OnPaneFailure;
            }
            EntryResponse response = await source.EntryAsync(entry);
            await pane.ShowAsync(response);
            target.Entry = entry.Clone();
            target.Dict = dictionary.Handle;
            target.Headword = entry.TryGetProperty("key", out JsonElement key) ? key.GetString() : query;
            target.Item.Header = target.Headword ?? query;
            ActivateTab(target);
        }
        finally
        {
            showGate.Release();
        }
        if (!record) return;
        trail.Push(new Visit(edition, entry.Clone(), query));
        UpdateTrail();
    }

    /// <summary>A new tab with its own WebView2 and pane folder; selecting it activates its state.</summary>
    private EntryTab NewTab(string title)
    {
        var host = new Grid();
        var item = new TabViewItem
        {
            Header = title.Length == 0 ? Strings.Get("entry.tab") : title,
            Content = host,
            IsClosable = true,
        };
        var tab = new EntryTab { Item = item, Host = host };
        tabs.Add(tab);
        Tabs.TabItems.Add(item);
        Tabs.SelectedItem = item;
        ActivateTab(tab);
        return tab;
    }

    private void ActivateTab(EntryTab tab)
    {
        paneLease = tab.Lease;
        currentEntry = tab.Entry;
        currentDict = tab.Dict;
        currentHeadword = tab.Headword;
    }

    /// <summary>The same entry already open in a tab: selecting it is the whole of the new-tab gesture.</summary>
    private bool SelectOpen(JsonElement entry)
    {
        if (!entry.TryGetProperty("edition", out JsonElement edition) ||
            !entry.TryGetProperty("key", out JsonElement key)) return false;
        string wantedEdition = edition.GetString() ?? "";
        string wantedKey = key.GetString() ?? "";
        uint wantedOccurrence = entry.TryGetProperty("occurrence", out JsonElement occurrence)
            ? occurrence.GetUInt32() : 0;
        foreach (EntryTab tab in tabs)
        {
            if (tab.Entry is not { } held ||
                held.GetProperty("edition").GetString() != wantedEdition ||
                held.GetProperty("key").GetString() != wantedKey ||
                held.GetProperty("occurrence").GetUInt32() != wantedOccurrence) continue;
            Tabs.SelectedItem = tab.Item;
            ActivateTab(tab);
            return true;
        }
        return false;
    }

    private void OnTabSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ActiveTab is { } tab) ActivateTab(tab);
    }

    private void OnTabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args)
    {
        EntryTab? tab = tabs.FirstOrDefault(item => item.Item == args.Tab);
        if (tab is null) return;
        Tabs.TabItems.Remove(tab.Item);
        tabs.Remove(tab);
        tab.Lease.Reset();
        foreach (PaneLease lease in tab.ExtraLeases) lease.Reset();
        if (tabs.Count == 0 || Tabs.SelectedItem is null)
        {
            paneLease = new PaneLease();
            currentEntry = null;
            currentDict = null;
            currentHeadword = null;
        }
        else if (ActiveTab is { } selected)
        {
            ActivateTab(selected);
        }
    }

    private void CloseAllTabs()
    {
        foreach (EntryTab tab in tabs.ToList())
        {
            Tabs.TabItems.Remove(tab.Item);
            tab.Lease.Reset();
            foreach (PaneLease lease in tab.ExtraLeases) lease.Reset();
        }
        tabs.Clear();
        paneLease = new PaneLease();
        currentEntry = null;
        currentDict = null;
        currentHeadword = null;
    }

    private async void OnPaneMessage(EntryBridgeMessage message) => await GuardAsync(async () =>
    {
        if (message.Kind == "word" && !string.IsNullOrWhiteSpace(message.Value))
        {
            SearchBox.Text = message.Value;
            await SearchAsync(message.Value);
            return;
        }
        // The entry's sound links are their own bridge kind (the rewriter preventDefaults the anchor), and the
        // service's link rule resolves them to the recording or the speech sentence.
        if (message.Kind is "link" or "sound" && !string.IsNullOrWhiteSpace(message.Value))
            await FollowLinkAsync(message.Value);
    });

    /// <summary>The renderer died: drop the pane so the next entry builds a live one instead of failing forever.</summary>
    private void OnPaneFailure(string reason)
    {
        paneLease.Reset();
        StatusText.Text = Strings.Get("entry.guardFailed");
        TraceFailure("renderer: " + reason);
    }

    /// <summary>A handler fault becomes a sentence, never an unhandled exception that ends the app.</summary>
    private async Task GuardAsync(Func<Task> work)
    {
        try
        {
            await work();
        }
        catch (OperationCanceledException)
        {
            // A newer gesture superseded this one.
        }
        catch (ServiceFailureException error)
        {
            StatusText.Text = error.Error is { } detail ? ServiceMessages.For(detail) : ServiceMessages.For(error.ErrorType);
        }
        catch (Exception error)
        {
            StatusText.Text = Strings.Get("entry.guardFailed");
            TraceFailure("handler: " + error.GetType().Name + ": " + error.Message);
        }
    }

    private static object ViewBody() => new { baseUrl = "https://xdict.local/", maxBodyBytes = 1 << 20 };

    private async Task FollowLinkAsync(string url, PaneContext? context = null)
    {
        string? dict = context?.Dict ?? currentDict;
        JsonElement? current = context?.Entry ?? currentEntry;
        if (client is null || current is not { } entry || dict is null) return;
        Reply reply = await client.CallAsync("link", new
        {
            dict, url, origin = new { type = "entry", entry }, view = ViewBody(),
        });
        if (reply.Error is { } error)
        {
            StatusText.Text = ServiceMessages.For(error);
            return;
        }
        JsonElement answer = reply.Ok!.Value;
        switch (answer.GetProperty("type").GetString())
        {
            case "lookup":
                string query = answer.GetProperty("query").GetString() ?? "";
                SearchBox.Text = query;
                await SearchAsync(query);
                break;
            case "sound":
                await PlayRecordingAsync(answer.GetProperty("path").GetString() ?? "", context);
                break;
            case "speak":
                await SpeakAsync(answer.GetProperty("text").GetString() ?? "", context);
                break;
            case "anchor":
                await ScrollAnchorAsync(answer.GetProperty("name").GetString() ?? "", context?.Pane);
                break;
        }
    }

    private async Task PlayRecordingAsync(string path, PaneContext? context = null)
    {
        string? dict = context?.Dict ?? currentDict;
        if (client is null || dict is null) return;
        Reply reply = await client.CallAsync("resource", new { dict, path, view = ViewBody() });
        if (reply.Error is not null) return;
        JsonElement ok = reply.Ok!.Value;
        bool found = ok.GetProperty("type").GetString() == "found";
        string? mime = found ? ok.GetProperty("mime").GetString() : null;
        if (!AppSettings.Load().UseRecordings)
        {
            await SpeakAsync(context?.Headword ?? currentHeadword ?? "", context);
            return;
        }
        SoundChoice choice = SoundSupport.Classify(path, found, mime);
        if (choice.Kind != SoundKind.Playable)
        {
            StatusText.Text = SoundSupport.Sentence(choice.Kind);
            if (choice.Kind == SoundKind.Unsupported) await SpeakAsync(context?.Headword ?? currentHeadword ?? "", context);
            return;
        }
        var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(reply.Payload ?? []);
            await writer.StoreAsync();
            writer.DetachStream();
        }
        stream.Seek(0);
        player?.Dispose();
        player = new MediaPlayer { Source = MediaSource.CreateFromStream(stream, mime ?? "audio/mpeg") };
        player.Play();
    }

    private async Task SpeakAsync(string text, PaneContext? context = null)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        using var synth = new SpeechSynthesizer();
        (string Name, string Language)[] voices = VoicePicker.Voices();
        string? edition = context is { } paneContext && paneContext.Entry.TryGetProperty("edition", out JsonElement held)
            ? held.GetString() : paneLease.Edition;
        string language = store?.Dictionaries.FirstOrDefault(item => item.Edition == edition)?.ExplainLanguage ?? "en";
        synth.Choose(voices, language, AppSettings.Load().Accent);
        // The entry's own IPA, when it has one, is what the voice should pronounce; the SSML names the voice's tag.
        string? ipa = await CurrentIpaAsync(context?.Pane);
        string tag = synth.Voice?.Language ?? language;
        SpeechSynthesisStream stream = ipa is null
            ? await synth.SynthesizeTextToStreamAsync(text)
            : await synth.SynthesizeSsmlToStreamAsync(SpeechText.Ssml(text, ipa, tag));
        player?.Dispose();
        player = new MediaPlayer { Source = MediaSource.CreateFromStream(stream, stream.ContentType) };
        player.Play();
    }

    /// <summary>The displayed entry's IPA, if it has a sane one; the page is the only place the entry's text lives.</summary>
    private async Task<string?> CurrentIpaAsync(EntryPane? pane = null)
    {
        if ((pane ?? paneLease.Pane)?.View.CoreWebView2 is not { } core) return null;
        try
        {
            string answer = await core.ExecuteScriptAsync(
                "Array.from(document.querySelectorAll('.t_IPA')).map(e=>e.textContent.trim()).find(t=>t.length>0&&t.length<120)||''");
            string ipa = JsonSerializer.Deserialize<string>(answer) ?? "";
            return ipa.Length > 0 ? ipa : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private async Task ScrollAnchorAsync(string name, EntryPane? pane = null)
    {
        if ((pane ?? paneLease.Pane)?.View.CoreWebView2 is not { } core) return;
        await core.ExecuteScriptAsync("document.getElementById(" + JsonSerializer.Serialize(name) + ")?.scrollIntoView()");
    }

    private async Task RestoreAsync()
    {
        if (trail.Current is not { } visit) return;
        await ShowAsync(visit.Edition, visit.Entry, visit.Query, record: false);
    }

    private void UpdateTrail()
    {
        BackButton.IsEnabled = trail.CanBack;
        ForwardButton.IsEnabled = trail.CanForward;
        ReturnButton.IsEnabled = trail.CanReturn;
    }

    private async void GoBack(object sender, RoutedEventArgs e)
    {
        if (trail.Back() is null) return;
        await GuardAsync(RestoreAsync);
        UpdateTrail();
    }

    private async void GoForward(object sender, RoutedEventArgs e)
    {
        if (trail.Forward() is null) return;
        await GuardAsync(RestoreAsync);
        UpdateTrail();
    }

    private async void GoReturn(object sender, RoutedEventArgs e)
    {
        if (trail.Return() is null) return;
        await GuardAsync(RestoreAsync);
        UpdateTrail();
    }

    private void GoBackAccel(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        GoBack(this, new RoutedEventArgs());
    }

    private void GoForwardAccel(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        GoForward(this, new RoutedEventArgs());
    }

    private void FocusSearchAccel(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        SearchBox.Focus(FocusState.Programmatic);
    }

    /// <summary>Find in the entry (Ctrl+F): WebView2's own page find, not a copy of the text it searches.</summary>
    private void FindAccel(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        FindBar.Visibility = Visibility.Visible;
        FindBox.Focus(FocusState.Programmatic);
        FindBox.SelectAll();
    }

    private async void OnFindTextChanged(object sender, TextChangedEventArgs e)
    {
        if (FindBar.Visibility == Visibility.Visible) await FindInEntryAsync(forward: true);
    }

    private async void OnFindKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            OnFindClose(this, new RoutedEventArgs());
        }
        else if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            bool shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            await FindInEntryAsync(forward: !shift);
        }
    }

    private async void OnFindNext(object sender, RoutedEventArgs e) => await FindInEntryAsync(forward: true);

    private async void OnFindPrevious(object sender, RoutedEventArgs e) => await FindInEntryAsync(forward: false);

    private void OnFindClose(object sender, RoutedEventArgs e)
    {
        FindBar.Visibility = Visibility.Collapsed;
        ActivePane?.View.Focus(FocusState.Programmatic);
    }

    private async Task FindInEntryAsync(bool forward)
    {
        string text = FindBox.Text;
        if (text.Length == 0 || ActivePane?.View.CoreWebView2 is not { } core) return;
        // The page's own find: the selection the reader sees is the browser's, and the entry tree is untouched.
        string script = "window.find(" + JsonSerializer.Serialize(text) + ", false, "
            + (forward ? "false" : "true") + ", true, false, false, false)";
        await core.ExecuteScriptAsync(script);
    }

    private void OpenSettings(object sender, RoutedEventArgs e)
    {
        if (client is null)
        {
            StatusText.Text = Strings.Get("app.serviceFailed");
            return;
        }
        // One Settings window, over the live store, so a dictionary added or disabled there reaches search and the
        // capture panel; closing it reopens the session against what the reader chose.
        if (settingsWindow is not null) { settingsWindow.Activate(); return; }
        LibraryStore live;
        try
        {
            live = store ?? LibraryStore.Load();
            store ??= live;
            settingsWindow = new SettingsWindow(live, client, capture, reminders);
        }
        catch (LibraryUnreadableException error)
        {
            StatusText.Text = Strings.Format("library.unreadable", error.Message);
            return;
        }
        // An import that finishes while Settings is open reaches search at once, not only when the window closes.
        settingsWindow.LibraryChanged += () => _ = GuardAsync(RefreshSessionAsync);
        settingsWindow.Closed += async (_, _) =>
        {
            settingsWindow = null;
            await GuardAsync(RefreshSessionAsync);
        };
        settingsWindow.Activate();
    }

    /// <summary>The review UIA lab's setup: a clean learning store and one note, so the queue has a card to grade.</summary>
    private async Task PrepareReviewLabAsync()
    {
        if (client is null || session is null || store is null) return;
        try
        {
            await new DataExport(client).EraseAsync();
            LibraryDictionary? dictionary = store.Dictionaries.FirstOrDefault(item =>
                item.Enabled && session.Dictionaries.Any(opened => opened.Edition == item.Edition));
            if (dictionary is null) return;
            Reply note = await client.CallAsync("studyNoteAt", new
            {
                entry = new { edition = dictionary.Edition, key = "run", occurrence = 0u },
                text = "review lab",
                name = dictionary.DisplayName,
                stamp = new { at = DateTimeOffset.UtcNow.ToUnixTimeSeconds(), device = DeviceIdentity.Current() },
                operation = "review-lab-" + Guid.NewGuid().ToString("N"),
            });
            if (note.Error is { } error) throw new ServiceFailureException(
                error.TryGetProperty("type", out JsonElement kind) ? kind.GetString() ?? "internal" : "internal", error);
            OpenReview();
        }
        catch (Exception error)
        {
            StatusText.Text = Strings.Format("review.loadFailed",
                error is ServiceFailureException failure ? ServiceMessages.For(failure.ErrorType) : error.Message);
        }
    }

    /// <summary>The tray's History item: one history window over the live service.</summary>
    private void OpenHistory()
    {
        if (client is null)
        {
            StatusText.Text = Strings.Get("app.serviceFailed");
            return;
        }
        if (historyWindow is not null)
        {
            historyWindow.Activate();
            return;
        }
        historyWindow = new HistoryWindow(client,
            card => _ = GuardAsync(() => OpenHistoryCardAsync(card)));
        historyWindow.Closed += (_, _) => historyWindow = null;
        historyWindow.Activate();
    }

    private Task OpenHistoryCardAsync(HistoryCard card) =>
        OpenEntryRefAsync(card.Reading.Edition, card.Reading.EntryKey, card.Reading.Occurrence, card.Reading.Surface);

    /// <summary>Explore over the dictionaries the session opened; a row opens its entry in this window.</summary>
    private void OpenExplore(object sender, RoutedEventArgs e)
    {
        if (client is null || session is null)
        {
            StatusText.Text = Strings.Get("app.serviceFailed");
            return;
        }
        if (exploreWindow is not null)
        {
            exploreWindow.Activate();
            return;
        }
        exploreWindow = new ExploreWindow(client, session.Dictionaries.ToList(),
            entry => _ = GuardAsync(() => OpenExploredAsync(entry)));
        exploreWindow.Closed += (_, _) => exploreWindow = null;
        exploreWindow.Activate();
    }

    private async Task OpenExploredAsync(JsonElement entry)
    {
        if (session is null) return;
        string edition = entry.GetProperty("edition").GetString() ?? "";
        if (!session.Dictionaries.Any(dictionary => dictionary.Edition == edition)) return;
        string key = entry.TryGetProperty("key", out JsonElement value) ? value.GetString() ?? "" : "";
        await ShowAsync(edition, entry, key, record: true, newTab: true);
        Activate();
    }

    /// <summary>The capture panel's Ask action: one meaning window over the captured sentence and the entry it drew.</summary>
    private void OpenMeaning(Capture.MeaningRequest request)
    {
        if (client is null)
        {
            StatusText.Text = Strings.Get("app.serviceFailed");
            return;
        }
        var window = new MeaningWindow(client, request);
        window.Activate();
    }

    /// <summary>The main window is hidden by X, never destroyed: the tray and the shortcut must find it again.</summary>
    public void ShowMainWindow()
    {
        AppWindow.Show();
        Activate();
        // A resume or a tray reopen is the moment to re-read the due date; the timer may have slept through it.
        _ = reminders?.RefreshAsync();
    }

    private async Task OpenFromTrayAsync(string term, double scroll)
    {
        ShowMainWindow();
        if (term.Length == 0) return;
        await LookupFromCaptureAsync(term, scroll);
    }

    private void OnMainWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (quitting) return;
        args.Cancel = true;
        AppWindow.Hide();
    }

    /// <summary>Quit, from the tray or the launch harness: settle the tray, the panes, the service and every window.</summary>
    public void Quit()
    {
        if (quitting) return;
        quitting = true;
        try { capture?.Dispose(); } catch (Exception) { }
        capture = null;
        reminders?.Dispose();
        reminders = null;
        CloseAllTabs();
        reviewWindow?.CloseForQuit();
        reviewWindow = null;
        try { settingsWindow?.Close(); } catch (Exception) { }
        settingsWindow = null;
        client?.Dispose();
        client = null;
        Application.Current.Exit();
    }

    /// <summary>The tray's Review item: one review window over the live service and the open dictionaries.</summary>
    private void OpenReview()
    {
        if (client is null || store is null || session is null)
        {
            StatusText.Text = Strings.Get("app.serviceFailed");
            return;
        }
        if (reviewWindow is not null)
        {
            reviewWindow.Activate();
            return;
        }
        reviewWindow = new ReviewWindow(client, store,
            edition => session.Dictionaries.FirstOrDefault(item => item.Edition == edition)?.Handle,
            edition => session.Dictionaries.Any(item => item.Edition == edition),
            card => _ = GuardAsync(() => OpenStudyCardAsync(card)));
        reviewWindow.Changed += () => _ = reminders?.RefreshAsync();
        reviewWindow.Closed += (_, _) => reviewWindow = null;
        reviewWindow.Activate();
    }

    /// <summary>Opens the card's exact entry: its key and occurrence, not the first hit of its headword.</summary>
    private Task OpenStudyCardAsync(StudyCard card) =>
        OpenEntryRefAsync(card.Target.Edition, card.Target.EntryKey, card.Target.Occurrence, card.Target.EntryKey);

    private async Task OpenEntryRefAsync(string edition, string key, uint occurrence, string query)
    {
        if (session is null) return;
        Activate();
        var found = new List<SearchHit>();
        await session.LookupEachAsync(key, edition, 50, page =>
        {
            lock (found) found.AddRange(page.Hits);
        });
        SearchHit? hit;
        lock (found)
        {
            hit = found.FirstOrDefault(item =>
                item.Entry.TryGetProperty("key", out JsonElement foundKey) &&
                foundKey.GetString() == key &&
                item.Entry.TryGetProperty("occurrence", out JsonElement foundOccurrence) &&
                foundOccurrence.GetUInt32() == occurrence);
        }
        if (hit is null)
        {
            StatusText.Text = Strings.Get("review.entryNotFound");
            return;
        }
        SearchBox.Text = query;
        await ShowAsync(hit.Edition, hit.Entry, query, record: true, newTab: true);
    }

    /// <summary>The first-run privacy choice: the history stays off until this is answered, and the answer is written.</summary>
    private async Task FirstRunDisclosureAsync()
    {
        if (client is null) return;
        try
        {
            var history = new HistorySession(client);
            if (!history.NeedsDisclosure) return;
            await windowLoaded.Task;
            if (Root.XamlRoot is null) return;
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = Strings.Get("history.disclosure.title"),
                Content = Strings.Get("history.disclosure"),
                PrimaryButtonText = Strings.Get("history.disclosure.keep"),
                CloseButtonText = Strings.Get("history.disclosure.off"),
            };
            ContentDialogResult result = await dialog.ShowAsync();
            if (result == ContentDialogResult.Primary) history.Disclose();
            else (LearningSettings.Load() with { HistoryDisclosed = true, HistoryEnabled = false }).Save();
        }
        catch (Exception error)
        {
            StatusText.Text = Strings.Format("history.failed", error.Message);
        }
    }

    /// <summary>Reopens the session against the library as it now stands; the scope box follows.</summary>
    private async Task RefreshSessionAsync()
    {
        if (quitting || session is null || store is null) return;
        string? chosen = SelectedEdition();
        // Reopening changes every handle and closes the panes built on the old ones, so the tabs are rebuilt rather
        // than left sending a stale handle. The entry on screen is the one the reader keeps.
        JsonElement? shown = currentEntry?.Clone();
        string? shownEdition = paneLease.Edition;
        CloseAllTabs();
        await session.OpenAsync(store.Dictionaries);
        // Reading & Speech is global: a stored edition preference follows the settings from now on. The old handle
        // also changed, so the next entry rebuilds its pane and reads the new preference.
        AppSettings settings = AppSettings.Load();
        ReadingPreferences current = ReadingPreferenceStore.FromSettings(settings, ThemeApplier.Effective(settings.Theme));
        foreach (LibraryDictionary dictionary in store.Dictionaries)
            if (readingPreferences.Has(dictionary.Edition)) readingPreferences.Write(dictionary.Edition, current);
        // Show the entry again: the refresh closed its handle, so this rebuilds the pane and reads the preference.
        if (shown is { } entry && shownEdition is { } edition &&
            session.Dictionaries.Any(item => item.Edition == edition))
            await ShowAsync(edition, entry, string.Empty, record: false);
        ScopeBox.Items.Clear();
        ScopeBox.Items.Add(Strings.Get("search.all"));
        foreach (OpenDictionary dictionary in session.Dictionaries) ScopeBox.Items.Add(dictionary.Name);
        int restore = chosen is null ? 0 : session.Dictionaries.ToList().FindIndex(item => item.Edition == chosen) + 1;
        ScopeBox.SelectedIndex = restore > 0 && restore < ScopeBox.Items.Count ? restore : 0;
    }

    private async Task WatchQuitAsync()
    {
        try
        {
            await probe!.WaitForQuitAsync();
        }
        catch (OperationCanceledException)
        {
            return;
        }
        DispatcherQueue.TryEnqueue(Quit);
    }
}

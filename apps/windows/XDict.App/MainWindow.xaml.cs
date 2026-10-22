// The main window: search the library's dictionaries, read an entry, and walk the trail.
using System.Text.Json;
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
    private readonly PaneLease paneLease = new();
    private RequestGeneration? searchGeneration;
    private IReadOnlyList<SearchHit> hits = [];
    private JsonElement? currentEntry;
    private string? currentDict;
    private string? currentHeadword;
    private readonly SemaphoreSlim showGate = new(1, 1);
    private SettingsWindow? settingsWindow;
    private MediaPlayer? player;
    private readonly Trail trail = new();
    private readonly ReadingPreferenceStore readingPreferences = new(ReadingPreferenceStore.DefaultPath);
    private Capture.CaptureController? capture;

    public MainWindow()
    {
        InitializeComponent();
        App.CurrentRoot = Root;
        ThemeApplier.Apply(Root, AppSettings.Load().Theme);
        Title = Strings.Get("app.title");
        LibraryButton.Content = Strings.Get("settings.title");
        BackButton.Content = Strings.Get("search.back");
        ForwardButton.Content = Strings.Get("search.forward");
        ReturnButton.Content = Strings.Get("search.return");
        SearchBox.PlaceholderText = Strings.Get("search.placeholder");
        AutomationProperties.SetName(SearchBox, Strings.Get("search.query"));
        AutomationProperties.SetName(ScopeBox, Strings.Get("search.scope"));
        AutomationProperties.SetName(Results, Strings.Get("search.resultsList"));
        AutomationProperties.SetName(BackButton, Strings.Get("search.back"));
        AutomationProperties.SetName(ForwardButton, Strings.Get("search.forward"));
        AutomationProperties.SetName(ReturnButton, Strings.Get("search.return"));
        AutomationProperties.SetName(LibraryButton, Strings.Get("settings.title"));
        UpdateTrail();
        StatusText.Text = Strings.Get("app.starting");
        // The client outlives this window: a Settings window can still be open and uses it; the process exit closes it.
        Closed += (_, _) => { capture?.Dispose(); paneLease.Reset(); };
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
                    EntryHost.Visibility = Visibility.Visible;
                    var browser = new Microsoft.UI.Xaml.Controls.WebView2();
                    EntryHost.Children.Add(browser);
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
            (term, scroll) => _ = GuardAsync(() => LookupFromCaptureAsync(term, scroll)));
        capture.SettingsRequested += () => OpenSettings(this, new RoutedEventArgs());
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
        await ShowAsync(hits[0].Edition, hits[0].Entry, term, record: true);
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
        await ShowAsync(hit.Edition, hit.Entry, SearchBox.Text, record: true);
    }

    private async Task ShowAsync(string edition, JsonElement entry, string query, bool record)
    {
        if (client is null || session is null) return;
        OpenDictionary dictionary = session.Dictionaries.First(item => item.Edition == edition);
        // One entry display at a time: a second selection while the first is still initializing would dispose a
        // half-built pane and let the first initialization continue on a closed view.
        await showGate.WaitAsync();
        try
        {
            // The handle changes when the session closes and reopens a dictionary; the old pane still sends it.
            bool rebuilt = !paneLease.Matches(edition, dictionary.Handle);
            if (rebuilt) EntryHost.Children.Clear();
            var (pane, source, built) = await paneLease.EnsureAsync(client, edition, dictionary.Handle,
                view => EntryHost.Children.Add(view), readingPreferences);
            if (built)
            {
                pane.Message += OnPaneMessage;
                pane.Failure += OnPaneFailure;
            }
            EntryResponse response = await source.EntryAsync(entry);
            await pane.ShowAsync(response);
        }
        finally
        {
            showGate.Release();
        }
        currentEntry = entry.Clone();
        currentDict = dictionary.Handle;
        currentHeadword = entry.TryGetProperty("key", out JsonElement key) ? key.GetString() : null;
        if (!record) return;
        trail.Push(new Visit(edition, entry.Clone(), query));
        UpdateTrail();
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

    private async Task FollowLinkAsync(string url)
    {
        if (client is null || currentEntry is not { } entry || currentDict is null) return;
        Reply reply = await client.CallAsync("link", new
        {
            dict = currentDict, url, origin = new { type = "entry", entry }, view = ViewBody(),
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
                await PlayRecordingAsync(answer.GetProperty("path").GetString() ?? "");
                break;
            case "speak":
                await SpeakAsync(answer.GetProperty("text").GetString() ?? "");
                break;
            case "anchor":
                await ScrollAnchorAsync(answer.GetProperty("name").GetString() ?? "");
                break;
        }
    }

    private async Task PlayRecordingAsync(string path)
    {
        if (client is null || currentDict is null) return;
        Reply reply = await client.CallAsync("resource", new { dict = currentDict, path, view = ViewBody() });
        if (reply.Error is not null) return;
        JsonElement ok = reply.Ok!.Value;
        bool found = ok.GetProperty("type").GetString() == "found";
        string? mime = found ? ok.GetProperty("mime").GetString() : null;
        if (!AppSettings.Load().UseRecordings)
        {
            await SpeakAsync(currentHeadword ?? "");
            return;
        }
        SoundChoice choice = SoundSupport.Classify(path, found, mime);
        if (choice.Kind != SoundKind.Playable)
        {
            StatusText.Text = SoundSupport.Sentence(choice.Kind);
            if (choice.Kind == SoundKind.Unsupported) await SpeakAsync(currentHeadword ?? "");
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

    private async Task SpeakAsync(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        using var synth = new SpeechSynthesizer();
        (string Name, string Language)[] voices = VoicePicker.Voices();
        string language = store?.Dictionaries.FirstOrDefault(item => item.Edition == paneLease.Edition)?.ExplainLanguage ?? "en";
        synth.Choose(voices, language, AppSettings.Load().Accent);
        // The entry's own IPA, when it has one, is what the voice should pronounce; the SSML names the voice's tag.
        string? ipa = await CurrentIpaAsync();
        string tag = synth.Voice?.Language ?? language;
        SpeechSynthesisStream stream = ipa is null
            ? await synth.SynthesizeTextToStreamAsync(text)
            : await synth.SynthesizeSsmlToStreamAsync(SpeechText.Ssml(text, ipa, tag));
        player?.Dispose();
        player = new MediaPlayer { Source = MediaSource.CreateFromStream(stream, stream.ContentType) };
        player.Play();
    }

    /// <summary>The displayed entry's IPA, if it has a sane one; the page is the only place the entry's text lives.</summary>
    private async Task<string?> CurrentIpaAsync()
    {
        if (paneLease.Pane?.View.CoreWebView2 is not { } core) return null;
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

    private async Task ScrollAnchorAsync(string name)
    {
        if (paneLease.Pane?.View.CoreWebView2 is not { } core) return;
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
            settingsWindow = new SettingsWindow(live, client, capture);
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

    /// <summary>Reopens the session against the library as it now stands; the scope box follows.</summary>
    private async Task RefreshSessionAsync()
    {
        if (session is null || store is null) return;
        string? chosen = SelectedEdition();
        await session.OpenAsync(store.Dictionaries);
        // Reading & Speech is global: a stored edition preference follows the settings from now on. The old handle
        // also changed, so the next entry rebuilds its pane and reads the new preference.
        AppSettings settings = AppSettings.Load();
        ReadingPreferences current = ReadingPreferenceStore.FromSettings(settings, ThemeApplier.Effective(settings.Theme));
        foreach (LibraryDictionary dictionary in store.Dictionaries)
            if (readingPreferences.Has(dictionary.Edition)) readingPreferences.Write(dictionary.Edition, current);
        // Show the entry again: the refresh closed its handle, so this rebuilds the pane and reads the preference.
        if (currentEntry is { } shown && paneLease.Edition is { } shownEdition &&
            session.Dictionaries.Any(item => item.Edition == shownEdition))
            await ShowAsync(shownEdition, shown, string.Empty, record: false);
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
        DispatcherQueue.TryEnqueue(() =>
        {
            client?.Dispose();
            Application.Current.Exit();
        });
    }
}

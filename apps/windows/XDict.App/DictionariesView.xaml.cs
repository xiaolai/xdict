// The reader's dictionary list: add a file, a folder or a drop; order, enable, name, languages, details; import with
// progress and cancel. The record and its rules live in XDict.Models; this window is the surface.
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using XDict.Client;
using XDict.Models;

namespace XDict.App;

public sealed partial class DictionariesView : UserControl
{
    private readonly Window owner;
    private readonly LibraryStore store;
    private readonly ServiceClient client;
    private readonly bool askLanguages;
    private CancellationTokenSource? importing;
    private List<LibraryDictionary> rows = [];

    public DictionariesView(LibraryStore store, ServiceClient client, Window owner, bool askLanguages = true)
    {
        InitializeComponent();
        this.askLanguages = askLanguages;
        this.store = store;
        this.client = client;
        this.owner = owner;
        AddFileButton.Content = Strings.Get("library.addFile");
        AddFolderButton.Content = Strings.Get("library.addFolder");
        UpButton.Content = Strings.Get("library.up");
        DownButton.Content = Strings.Get("library.down");
        ToggleButton.Content = Strings.Get("library.toggle");
        RemoveButton.Content = Strings.Get("library.remove");
        DetailsButton.Content = Strings.Get("library.details");
        JoinButton.Content = Strings.Get("library.join");
        SplitButton.Content = Strings.Get("library.split");
        CancelButton.Content = Strings.Get("library.cancel");
        RelinkMissing();
        Refresh();
    }

    /// <summary>A folder the reader moved: each missing package is looked for one level above its own folder's parent,
    /// where the moved folder now sits, and its files follow the identity recorded at import.</summary>
    private void RelinkMissing()
    {
        foreach (LibraryDictionary record in store.Dictionaries.ToList())
        {
            LibraryFile? mdx = record.Files.FirstOrDefault(file => file.Role == LibraryRole.Mdx);
            if (mdx is null || File.Exists(mdx.Path)) continue;
            string? folder = Path.GetDirectoryName(mdx.Path);
            string? root = folder is null ? null : Path.GetDirectoryName(folder);
            if (root is null || !Directory.Exists(root)) continue;
            try
            {
                LibraryDictionary? relocated = LibraryRelinker.Relink(record, root);
                if (relocated is not null) store.Add(relocated);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // One unreadable tree must not stop Settings from opening; the record keeps its missing state.
            }
        }
    }

    /// <summary>Raised after the library changed (an import or a toggle/remove/move), so the session can follow.</summary>
    public event Action? LibraryChanged;

    public string StatusText => Status.Text;

    private LibraryDictionary? Selected =>
        Dictionaries.SelectedIndex >= 0 && Dictionaries.SelectedIndex < rows.Count
            ? rows[Dictionaries.SelectedIndex]
            : null;

    private void Refresh()
    {
        RefreshRows();
        if (rows.Count == 0) Status.Text = Strings.Get("library.empty");
    }

    /// <summary>The list without a status sentence: a failed batch keeps its own sentence while showing what saved.</summary>
    private void RefreshRows()
    {
        rows = store.Dictionaries.ToList();
        Dictionaries.ItemsSource = rows.Select(Describe).ToList();
        if (rows.Count == 1) Dictionaries.SelectedIndex = 0;
    }

    private static string Describe(LibraryDictionary dictionary) =>
        $"{(dictionary.Enabled ? "✓" : " ")} {dictionary.DisplayName} — {dictionary.Title} · " +
        $"{dictionary.SearchLanguage}→{dictionary.ExplainLanguage} · {dictionary.Edition}";

    /// <summary>An async void handler's fault becomes a sentence: nothing it throws may end the app.</summary>
    private async Task Guarded(Func<Task> work)
    {
        try { await work(); }
        catch (OperationCanceledException) { }
        catch (Exception error) { Status.Text = Strings.Format("library.failed", "", error.Message); }
    }

    private async void AddFile(object sender, RoutedEventArgs e) => await Guarded(async () =>
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
        picker.FileTypeFilter.Add(".mdx");
        StorageFile? file = await picker.PickSingleFileAsync();
        if (file is not null) await AddPathsAsync([file.Path]);
    });

    private async void AddFolder(object sender, RoutedEventArgs e) => await Guarded(async () =>
    {
        var picker = new FolderPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
        picker.FileTypeFilter.Add("*");
        StorageFolder? folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        IReadOnlyList<string> found = PackageFinder.MdxIn(folder.Path);
        if (found.Count == 0) { Status.Text = Strings.Get("library.noMdx"); return; }
        await AddPathsAsync(found);
    });

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.IsCaptionVisible = false;
    }

    private async void OnDrop(object sender, DragEventArgs e) => await Guarded(async () =>
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var mdx = new List<string>();
        foreach (IStorageItem item in await e.DataView.GetStorageItemsAsync())
        {
            if (item is StorageFile file && file.Path.EndsWith(".mdx", StringComparison.OrdinalIgnoreCase))
                mdx.Add(file.Path);
            else if (item is StorageFolder folder)
                mdx.AddRange(PackageFinder.MdxIn(folder.Path));
        }
        if (mdx.Count == 0) { Status.Text = Strings.Get("library.noMdx"); return; }
        await AddPathsAsync(mdx);
    });

    public async Task AddPathsAsync(IReadOnlyList<string> paths)
    {
        // One import at a time: a second drop while the first runs would overwrite `importing`, so the first
        // finally would dispose the second's source and Cancel would target the wrong import.
        if (importing is not null) { Status.Text = Strings.Get("library.busy"); return; }
        var cancellation = new CancellationTokenSource();
        importing = cancellation;
        CancelButton.Visibility = Visibility.Visible;
        string current = "";
        try
        {
            foreach (string mdx in paths)
            {
                string name = Path.GetFileName(mdx);
                current = name;
                Status.Text = Strings.Format("library.importing", name);
                PackageFiles package = PackageFinder.Discover(mdx);
                LibraryDictionary? existing = store.Dictionaries.FirstOrDefault(item =>
                    item.Files.Any(file => file.Role == LibraryRole.Mdx &&
                        string.Equals(file.Path, mdx, StringComparison.OrdinalIgnoreCase)));
                LibraryDictionary imported = await LibraryImporter.ImportAsync(
                    client, package, existing: existing, cancellation: cancellation.Token);
                LibraryDictionary inspected = await LibraryInspector.InspectAsync(client, imported, cancellation.Token);
                // A changed file is a new edition at the same path: the previous record would search twice.
                foreach (LibraryDictionary stale in store.Dictionaries.Where(item =>
                             item.Edition != inspected.Edition &&
                             item.Files.Any(file => file.Role == LibraryRole.Mdx &&
                                 string.Equals(file.Path, mdx, StringComparison.OrdinalIgnoreCase))).ToList())
                    store.Remove(stale.Edition);
                store.Add(inspected);
                Status.Text = Strings.Format("library.imported", inspected.DisplayName);
                if (askLanguages && !PackageFinder.Guess(mdx).Certain)
                    await AskLanguagesAsync(inspected.Edition);
            }
            Refresh();
            LibraryChanged?.Invoke();
        }
        catch (OperationCanceledException)
        {
            Status.Text = Strings.Get("library.cancelled");
        }
        catch (PackageIncompleteException error)
        {
            Status.Text = Strings.Format("library.missingVolume", Path.GetFileName(error.Mdx),
                string.Join(", ", error.Volumes));
        }
        catch (ServiceFailureException error)
        {
            // The client answers a cancelled import with a typed "cancelled" reply, not an exception from the call.
            if (error.ErrorType == "cancelled")
            {
                Status.Text = Strings.Get("library.cancelled");
            }
            else
            {
                string sentence = error.Error is { } detail ? ServiceMessages.For(detail) : ServiceMessages.For(error.ErrorType);
                Status.Text = Strings.Format("library.failed", current, sentence);
            }
        }
        catch (ReparseRefusedException)
        {
            Status.Text = Strings.Format("library.refused", current);
        }
        catch (Exception error)
        {
            // A drop handler is async void: anything it lets escape ends the app.
            Status.Text = Strings.Format("library.failed", current, error.Message);
        }
        finally
        {
            // Earlier files of a failed or cancelled batch are already saved; the list must show them.
            RefreshRows();
            if (ReferenceEquals(importing, cancellation)) importing = null;
            cancellation.Dispose();
            CancelButton.Visibility = Visibility.Collapsed;
        }
    }

    private void Cancel(object sender, RoutedEventArgs e) => importing?.Cancel();

    /// <summary>A store change that may fail on a locked or full disk: the list keeps working and says so.</summary>
    private void Mutate(Action change)
    {
        try { change(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Status.Text = Strings.Format("library.failed", "", error.Message);
            return;
        }
        Refresh();
        LibraryChanged?.Invoke();
    }

    private async void Join(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } dictionary) return;
        var targets = store.Dictionaries.Where(item => item.Edition != dictionary.Edition).ToList();
        if (targets.Count == 0) return;
        var picker = new ComboBox { ItemsSource = targets.Select(item => item.DisplayName + " — " + item.Title).ToList() };
        picker.SelectedIndex = 0;
        var dialog = new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = Strings.Get("library.join"),
            Content = new StackPanel
            {
                Spacing = 8,
                Children = { new TextBlock { Text = Strings.Get("library.joinPrompt"), TextWrapping = TextWrapping.Wrap }, picker },
            },
            PrimaryButtonText = Strings.Get("library.join"),
            CloseButtonText = Strings.Get("library.cancel"),
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        int chosen = picker.SelectedIndex;
        if (chosen < 0 || chosen >= targets.Count) return;
        try
        {
            string joined = await LibraryJoiner.JoinAsync(client, dictionary.Edition, targets[chosen].Lineage);
            store.SetLineage(dictionary.Edition, joined);
            Status.Text = Strings.Format("library.joined", targets[chosen].DisplayName);
            Refresh();
        }
        catch (ServiceFailureException error)
        {
            Status.Text = Strings.Format("library.failed", dictionary.DisplayName, ServiceMessages.For(error.ErrorType));
        }
        catch (Exception error)
        {
            Status.Text = Strings.Format("library.failed", dictionary.DisplayName, error.Message);
        }
    }

    private async void Split(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } dictionary) return;
        try
        {
            string split = await LibraryJoiner.SplitAsync(client, dictionary.Edition, Guid.NewGuid().ToString());
            store.SetLineage(dictionary.Edition, split);
            Status.Text = Strings.Get("library.splitDone");
            Refresh();
        }
        catch (ServiceFailureException error)
        {
            Status.Text = Strings.Format("library.failed", dictionary.DisplayName, ServiceMessages.For(error.ErrorType));
        }
        catch (Exception error)
        {
            Status.Text = Strings.Format("library.failed", dictionary.DisplayName, error.Message);
        }
    }

    private async Task AskLanguagesAsync(string edition)
    {
        string[] languages = ["en", "zh-Hans", "zh-Hant", "ja", "fr", "de", "es"];
        var search = new ComboBox { ItemsSource = languages.ToList(), SelectedItem = "en" };
        var explain = new ComboBox { ItemsSource = languages.ToList(), SelectedItem = "en" };
        var dialog = new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = Strings.Get("library.askLanguages"),
            Content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new TextBlock { Text = Strings.Get("library.searchLanguage") }, search,
                    new TextBlock { Text = Strings.Get("library.explainLanguage") }, explain,
                },
            },
            PrimaryButtonText = Strings.Get("library.keep"),
            CloseButtonText = Strings.Get("library.cancel"),
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && search.SelectedItem is string s && explain.SelectedItem is string e)
            store.SetLanguages(edition, s, e);
    }

    private void MoveUp(object sender, RoutedEventArgs e) => Move(-1);

    private void MoveDown(object sender, RoutedEventArgs e) => Move(1);

    private void Move(int delta)
    {
        if (Selected is { } dictionary) Mutate(() => store.Move(dictionary.Edition, delta));
    }

    private void Toggle(object sender, RoutedEventArgs e)
    {
        if (Selected is { } dictionary) Mutate(() => store.SetEnabled(dictionary.Edition, !dictionary.Enabled));
    }

    private void Remove(object sender, RoutedEventArgs e)
    {
        if (Selected is { } dictionary) Mutate(() => store.Remove(dictionary.Edition));
    }

    private void ShowDetails(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } dictionary) { DetailsText.Text = Strings.Get("library.select"); return; }
        var text = new StringBuilder();
        text.AppendLine(dictionary.DisplayName + " — " + dictionary.Title);
        text.AppendLine(dictionary.Edition);
        text.AppendLine(dictionary.Lineage);
        text.AppendLine(Strings.Format("library.files", dictionary.Files.Count));
        text.AppendLine(dictionary.SearchLanguage + " → " + dictionary.ExplainLanguage);
        if (dictionary.HealthJson is { } health)
            text.AppendLine(Strings.Get("library.health") + ": " + health);
        if (dictionary.StyleJson is { } style)
            text.AppendLine(Strings.Get("library.style") + ": " + style);
        // Whether the files are still the ones recorded at import: a moved, missing or rewritten file is said here.
        IReadOnlyList<LibraryFileCheck> checks = LibraryVerifier.Check(dictionary);
        int missing = checks.Count(check => check.State == LibraryFileState.Missing);
        int changed = checks.Count(check => check.State == LibraryFileState.Changed);
        if (missing > 0 || changed > 0)
        {
            text.AppendLine(Strings.Format("library.fileStates", missing, changed));
            foreach (LibraryFileCheck check in checks.Where(item => item.State != LibraryFileState.Ok))
                text.AppendLine("  " + check.Path + " — " +
                    Strings.Get(check.State == LibraryFileState.Missing ? "library.fileMissing" : "library.fileChanged"));
        }
        DetailsText.Text = text.ToString();
    }
}

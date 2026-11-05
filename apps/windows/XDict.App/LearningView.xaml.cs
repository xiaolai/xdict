// Learning (ADR-0023): the review target, and the reader's own export and erase of what XDict keeps on this PC.
// The history switch and its first-run disclosure are WS-P2's, behind Probe A; this pane holds no history surface.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage;
using Windows.Storage.Pickers;
using XDict.Client;
using XDict.Models;

namespace XDict.App;

public sealed partial class LearningView : UserControl
{
    private static readonly double[] Retentions = [0.80, 0.85, 0.90, 0.95];

    private readonly Window owner;
    private readonly LibraryStore store;
    private readonly ServiceClient client;
    private readonly ReviewReminders? reminders;
    private LearningSettings settings;
    private bool loading = true;

    public LearningView(Window owner, LibraryStore store, ServiceClient client, ReviewReminders? reminders = null)
    {
        InitializeComponent();
        this.owner = owner;
        this.store = store;
        this.client = client;
        this.reminders = reminders;
        settings = LearningSettings.Load();
        Heading.Text = Strings.Get("settings.learning");
        HistorySwitch.Header = Strings.Get("learning.history");
        HistoryDetail.Text = Strings.Get("learning.historyDetail");
        HistorySwitch.IsOn = settings.HistoryEnabled;
        LanguagesLabel.Text = Strings.Get("learning.languages");
        LanguagesDetail.Text = Strings.Get("learning.languagesDetail");
        NoLanguages.Text = Strings.Get("learning.noLanguages");
        BuildLanguages();
        RetentionLabel.Text = Strings.Get("learning.retention");
        RetentionDetail.Text = Strings.Get("learning.retentionDetail");
        Reminders.Header = Strings.Get("learning.reminders");
        RemindersDetail.Text = Strings.Get("learning.remindersDetail");
        Reminders.IsOn = settings.RemindersEnabled;
        NotificationSettings.Content = Strings.Get("learning.openNotificationSettings");
        SyncLabel.Text = Strings.Get("sync.title");
        SyncDetail.Text = Strings.Get("sync.detail");
        ChooseSyncFolder.Content = Strings.Get("sync.choose");
        SyncNow.Content = Strings.Get("sync.now");
        UpdateSyncFolder();
        ExportLabel.Text = Strings.Get("learning.export");
        ExportDetail.Text = Strings.Get("learning.exportDetail");
        ExportButton.Content = Strings.Get("learning.exportAction");
        EraseLabel.Text = Strings.Get("learning.erase");
        EraseDetail.Text = Strings.Get("learning.eraseDetail");
        EraseButton.Content = Strings.Get("learning.eraseAction");
        foreach (double value in Retentions)
            Retention.Items.Add(Strings.Format("learning.retentionOption", (int)Math.Round(value * 100)));
        int selected = Array.FindIndex(Retentions,
            value => Math.Abs(value - settings.ReviewRetention) < 0.001);
        Retention.SelectedIndex = selected < 0 ? 2 : selected;
        loading = false;
        UpdateReminderState();
    }

    private void OnRemindersToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        settings = settings with { RemindersEnabled = Reminders.IsOn };
        Save();
        _ = reminders?.RefreshAsync();
        UpdateReminderState();
    }

    /// <summary>The capability and Windows' permission are said where the reader chooses reminders (AGENTS.md).</summary>
    private void UpdateReminderState()
    {
        NotificationSettings.Visibility = Visibility.Collapsed;
        if (reminders is null || !reminders.Supported || reminders.Permission == ReminderPermission.Unsupported)
        {
            Reminders.IsEnabled = false;
            RemindersStatus.Text = Strings.Get("learning.remindersUnsupported");
            return;
        }
        Reminders.IsEnabled = true;
        if (reminders.Permission == ReminderPermission.Denied)
        {
            RemindersStatus.Text = Strings.Get("learning.remindersBlocked");
            NotificationSettings.Visibility = Visibility.Visible;
            return;
        }
        RemindersStatus.Text = reminders.Permission == ReminderPermission.Unspecified
            ? Strings.Get("learning.remindersAsk")
            : "";
    }

    private async void OnNotificationSettings(object sender, RoutedEventArgs e)
    {
        try { await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications")); }
        catch (Exception error) { Status.Text = Strings.Format("learning.settingsFailed", error.Message); }
    }

    private void BuildLanguages()
    {
        LanguageList.Children.Clear();
        string[] languages = store.Dictionaries.Where(item => item.Enabled)
            .SelectMany(item => new[] { item.SearchLanguage, item.ExplainLanguage })
            .Where(language => !string.IsNullOrWhiteSpace(language))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(language => language, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        foreach (string language in languages)
        {
            var box = new CheckBox
            {
                Content = language,
                Tag = language,
                IsChecked = settings.Targets.Contains(language, StringComparer.OrdinalIgnoreCase),
            };
            box.Checked += OnLanguageToggled;
            box.Unchecked += OnLanguageToggled;
            LanguageList.Children.Add(box);
        }
        NoLanguages.Visibility = languages.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnHistoryToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        settings = settings with
        {
            HistoryEnabled = HistorySwitch.IsOn,
            HistoryDisclosed = HistorySwitch.IsOn ? true : settings.HistoryDisclosed,
        };
        Save();
    }

    private void OnLanguageToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        string[] chosen = LanguageList.Children.OfType<CheckBox>()
            .Where(box => box.IsChecked == true && box.Tag is string)
            .Select(box => (string)box.Tag)
            .ToArray();
        settings = settings with { TargetLanguages = chosen.ToList() };
        Save();
    }

    private void OnRetentionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || Retention.SelectedIndex < 0 || Retention.SelectedIndex >= Retentions.Length) return;
        settings = settings with { ReviewRetention = Retentions[Retention.SelectedIndex] };
        Save();
    }

    private void Save()
    {
        try
        {
            settings.Save();
            Status.Text = "";
        }
        catch (Exception error)
        {
            Status.Text = Strings.Format("settings.saveFailed", error.Message);
        }
    }

    private void UpdateSyncFolder()
    {
        bool chosen = !string.IsNullOrWhiteSpace(settings.SyncFolder);
        SyncFolderText.Text = chosen ? settings.SyncFolder! : Strings.Get("sync.notSet");
        SyncNow.IsEnabled = chosen;
    }

    private async void OnChooseSyncFolder(object sender, RoutedEventArgs e)
    {
        try
        {
            var picker = new FolderPicker();
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
            picker.FileTypeFilter.Add("*");
            picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
            StorageFolder? folder = await picker.PickSingleFolderAsync();
            if (folder is null) return;
            settings = settings with { SyncFolder = folder.Path };
            Save();
            UpdateSyncFolder();
            SyncStatus.Text = "";
        }
        catch (Exception error)
        {
            SyncStatus.Text = Strings.Format("sync.chooseFailed", error.Message);
        }
    }

    private async void OnSyncNow(object sender, RoutedEventArgs e)
    {
        if (settings.SyncFolder is not { } folder) return;
        SyncNow.IsEnabled = false;
        SyncStatus.Text = Strings.Get("sync.running");
        try
        {
            SyncReport report = await new SyncSession(client).SyncAsync(folder);
            SyncStatus.Text = Strings.Format("sync.done", report.Peers, report.Added, report.Skipped);
        }
        catch (SyncLimitException error)
        {
            SyncStatus.Text = Strings.Format("sync.limit", error.Message);
        }
        catch (ServiceFailureException error)
        {
            SyncStatus.Text = Strings.Format("sync.failed", ServiceMessages.For(error.ErrorType));
        }
        catch (Exception error)
        {
            SyncStatus.Text = Strings.Format("sync.failed", error.Message);
        }
        finally
        {
            SyncNow.IsEnabled = !string.IsNullOrWhiteSpace(settings.SyncFolder);
        }
    }

    private async void OnExport(object sender, RoutedEventArgs e)
    {
        try
        {
            var picker = new FileSavePicker { SuggestedFileName = Strings.Get("learning.exportFileName") };
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
            picker.FileTypeChoices.Add(Strings.Get("learning.exportPicker"), new List<string> { ".json" });
            StorageFile? file = await picker.PickSaveFileAsync();
            if (file is null) return;
            DataExportResult result = await new DataExport(client).ExportAsync(file.Path);
            Status.Text = Strings.Format("learning.exported", result.Path);
        }
        catch (Exception error)
        {
            Status.Text = Strings.Format("learning.exportFailed", Describe(error));
        }
    }

    private async void OnErase(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Get("learning.erase"),
            Content = Strings.Get("learning.eraseConfirm"),
            PrimaryButtonText = Strings.Get("learning.eraseAction"),
            CloseButtonText = Strings.Get("learning.eraseCancel"),
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            EraseReport report = await new DataExport(client).EraseAsync();
            Status.Text = Strings.Format("learning.erased", report.ClearedReadings, report.ClearedNotes,
                report.ClearedGrades, report.Recoverable);
        }
        catch (Exception error)
        {
            // No automatic retry: a lost acknowledgement is settled by the next export, which shows the receipt.
            Status.Text = Strings.Format("learning.eraseFailed", Describe(error));
        }
    }

    private static string Describe(Exception error) =>
        error is ServiceFailureException failure ? ServiceMessages.For(failure.ErrorType) : error.Message;
}

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
    private readonly ServiceClient client;
    private LearningSettings settings;
    private bool loading = true;

    public LearningView(Window owner, ServiceClient client)
    {
        InitializeComponent();
        this.owner = owner;
        this.client = client;
        settings = LearningSettings.Load();
        Heading.Text = Strings.Get("settings.learning");
        RetentionLabel.Text = Strings.Get("learning.retention");
        RetentionDetail.Text = Strings.Get("learning.retentionDetail");
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

// Reading & Speech (ADR-0012): the reading face's defaults, the dictionary's own recordings, and the accent.
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using XDict.Models;

namespace XDict.App;

public sealed partial class ReadingSpeechView : UserControl
{
    private readonly AppSettings settings;
    private bool loading = true;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer zoomSave;

    public ReadingSpeechView()
    {
        InitializeComponent();
        settings = AppSettings.Load();
        Heading.Text = Strings.Get("settings.reading");
        ZoomLabel.Text = Strings.Get("settings.zoom");
        OriginalStyle.Header = Strings.Get("settings.originalStyle");
        UseRecordings.Header = Strings.Get("settings.useRecordings");
        AccentLabel.Text = Strings.Get("settings.accent");
        Accent.Items.Add(Strings.Get("settings.accent.us"));
        Accent.Items.Add(Strings.Get("settings.accent.uk"));
        // One drag fires dozens of ValueChanged events; the file is written once, a moment after it settles.
        zoomSave = DispatcherQueue.CreateTimer();
        zoomSave.Interval = TimeSpan.FromMilliseconds(250);
        zoomSave.IsRepeating = false;
        zoomSave.Tick += (_, _) => Save(current => current with { Zoom = Zoom.Value });
        Unloaded += (_, _) =>
        {
            if (!zoomSave.IsRunning) return;
            zoomSave.Stop();
            Save(current => current with { Zoom = Zoom.Value });
        };
        Zoom.Value = settings.Zoom;
        OriginalStyle.IsOn = settings.OriginalStyle;
        UseRecordings.IsOn = settings.UseRecordings;
        Accent.SelectedIndex = settings.Accent == "uk" ? 1 : 0;
        UpdateZoomText();
        loading = false;
    }

    private void UpdateZoomText() =>
        ZoomValue.Text = Strings.Format("settings.zoomPercent", (int)Math.Round(Zoom.Value * 100));

    private void OnZoomChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (loading) return;
        UpdateZoomText();
        zoomSave.Stop();
        zoomSave.Start();
    }

    private void OnOriginalStyleToggled(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (!loading) Save(current => current with { OriginalStyle = OriginalStyle.IsOn });
    }

    private void OnRecordingsToggled(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (!loading) Save(current => current with { UseRecordings = UseRecordings.IsOn });
    }

    private void OnAccentChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!loading) Save(current => current with { Accent = Accent.SelectedIndex == 1 ? "uk" : "us" });
    }

    /// <summary>Writes one field onto the file as it is now: another page's change is never clobbered.</summary>
    private void Save(Func<AppSettings, AppSettings> change)
    {
        try { change(AppSettings.Load()).Save(); }
        catch (Exception error) { Status.Text = Strings.Format("settings.saveFailed", error.Message); }
    }
}

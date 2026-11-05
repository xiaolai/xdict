// Reading (ADR-0012): the entry's zoom and the dictionary's own style. Speech's controls live in their own pane.
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using XDict.Models;

namespace XDict.App;

public sealed partial class ReadingView : UserControl
{
    private readonly AppSettings settings;
    private bool loading = true;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer zoomSave;

    public ReadingView()
    {
        InitializeComponent();
        settings = AppSettings.Load();
        Heading.Text = Strings.Get("settings.reading");
        ZoomLabel.Text = Strings.Get("settings.zoom");
        OriginalStyle.Header = Strings.Get("settings.originalStyle");
        // One drag fires dozens of ValueChanged events; the file is written once, a moment after it settles.
        zoomSave = DispatcherQueue.CreateTimer();
        zoomSave.Interval = TimeSpan.FromMilliseconds(Tokens.Motion.SaveDebounce);
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

    /// <summary>Writes one field onto the file as it is now: another page's change is never clobbered.</summary>
    private void Save(Func<AppSettings, AppSettings> change)
    {
        try { change(AppSettings.Load()).Save(); }
        catch (Exception error) { Status.Text = Strings.Format("settings.saveFailed", error.Message); }
    }
}

// Speech (ADR-0012): the dictionary's own recordings and the spoken accent. Reading's controls live in their pane.
using Microsoft.UI.Xaml.Controls;
using XDict.Models;

namespace XDict.App;

public sealed partial class SpeechView : UserControl
{
    private readonly AppSettings settings;
    private bool loading = true;

    public SpeechView()
    {
        InitializeComponent();
        settings = AppSettings.Load();
        Heading.Text = Strings.Get("settings.speech");
        UseRecordings.Header = Strings.Get("settings.useRecordings");
        AccentLabel.Text = Strings.Get("settings.accent");
        Accent.Items.Add(Strings.Get("settings.accent.us"));
        Accent.Items.Add(Strings.Get("settings.accent.uk"));
        UseRecordings.IsOn = settings.UseRecordings;
        Accent.SelectedIndex = settings.Accent == "uk" ? 1 : 0;
        loading = false;
    }

    private void OnRecordingsToggled(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        if (!loading) Save(current => current with { UseRecordings = UseRecordings.IsOn });
    }

    private void OnAccentChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!loading) Save(current => current with { Accent = Accent.SelectedIndex == 1 ? "uk" : "us" });
    }

    private void Save(Func<AppSettings, AppSettings> change)
    {
        try { change(AppSettings.Load()).Save(); }
        catch (Exception error) { Status.Text = Strings.Format("settings.saveFailed", error.Message); }
    }
}

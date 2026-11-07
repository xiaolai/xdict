// General (ADR-0012): the theme and start at login. Lookup, About and Speech have their own panes.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using XDict.Models;

namespace XDict.App;

public sealed partial class GeneralView : UserControl
{
    private bool loading = true;

    public GeneralView()
    {
        InitializeComponent();
        AppSettings settings = AppSettings.Load();
        Heading.Text = Strings.Get("settings.general");
        ThemeLabel.Text = Strings.Get("settings.theme");
        AutomationProperties.SetLabeledBy(Theme, ThemeLabel);
        Theme.Items.Add(Strings.Get("settings.theme.system"));
        Theme.Items.Add(Strings.Get("settings.theme.light"));
        Theme.Items.Add(Strings.Get("settings.theme.dark"));
        Theme.SelectedIndex = settings.Theme switch { "light" => 1, "dark" => 2, _ => 0 };
        StartAtLogin.Header = Strings.Get("settings.startAtLogin");
        StartAtLogin.IsOn = StartupRegistration.IsEnabled();
        loading = false;
    }

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading) return;
        string theme = Theme.SelectedIndex switch { 1 => "light", 2 => "dark", _ => "system" };
        try { (AppSettings.Load() with { Theme = theme }).Save(); }
        catch (Exception error) { Status.Text = Strings.Format("settings.saveFailed", error.Message); }
        ThemeApplier.Apply(XamlRoot?.Content as FrameworkElement, theme);
        ThemeApplier.Publish(theme);
    }

    private void OnStartAtLoginToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        bool wanted = StartAtLogin.IsOn;
        if (StartupRegistration.Set(wanted))
        {
            try { (AppSettings.Load() with { StartAtLogin = wanted }).Save(); }
            catch (Exception error) { Status.Text = Strings.Format("settings.saveFailed", error.Message); }
            return;
        }
        // Put the switch back without re-entering this handler: a failed write in both directions ping-pongs.
        loading = true;
        StartAtLogin.IsOn = !wanted;
        loading = false;
        Status.Text = Strings.Get("settings.startupFailed");
    }
}

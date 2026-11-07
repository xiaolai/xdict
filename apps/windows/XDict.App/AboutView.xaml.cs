// About: the version and the acknowledgements a reader can read inside the app.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using XDict.Models;

namespace XDict.App;

public sealed partial class AboutView : UserControl
{
    public AboutView()
    {
        InitializeComponent();
        Heading.Text = Strings.Get("settings.about");
        string version = typeof(AboutView).Assembly.GetName().Version?.ToString() ?? "";
        VersionText.Text = Strings.Format("about.version", version);
        AcknowledgementsButton.Content = Strings.Get("about.acknowledgements");
    }

    private async void OnAcknowledgements(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Strings.Get("about.acknowledgements"),
            Content = new ScrollViewer
            {
                Content = new TextBlock
                {
                    Text = Notices.Text,
                    TextWrapping = TextWrapping.Wrap,
                    IsTextSelectionEnabled = true,
                },
            },
            CloseButtonText = Strings.Get("settings.close"),
        };
        try { await dialog.ShowAsync(); }
        catch (Exception error)
        {
            // Another window can already own this UI thread's dialog; the notices are not worth a crash.
            System.Diagnostics.Debug.WriteLine("notices: " + error.Message);
        }
    }
}

// One Settings window (ADR-0012): Dictionaries (the only dictionary list), Reading & Speech, General. Every route is a
// NavigationView item, reachable by keyboard and named for UI Automation.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using XDict.Client;
using XDict.Models;

namespace XDict.App;

public sealed partial class SettingsWindow : Window
{
    /// <summary>A batch of dictionaries was imported while this window is open.</summary>
    public event Action? LibraryChanged;

    private readonly DictionariesView dictionaries;
    private readonly ReadingSpeechView reading;
    private readonly GeneralView general;

    public SettingsWindow(LibraryStore store, ServiceClient client, Capture.CaptureController? capture = null)
    {
        InitializeComponent();
        // Every window follows the saved theme, not only the main window that applied it before opening this one.
        ThemeApplier.Apply(Content as Microsoft.UI.Xaml.FrameworkElement, AppSettings.Load().Theme);
        Title = Strings.Get("settings.title");
        DictionariesItem.Content = Strings.Get("settings.dictionaries");
        ReadingItem.Content = Strings.Get("settings.reading");
        GeneralItem.Content = Strings.Get("settings.general");
        dictionaries = new DictionariesView(store, client, this);
        dictionaries.LibraryChanged += () => LibraryChanged?.Invoke();
        reading = new ReadingSpeechView();
        general = new GeneralView(capture);
        foreach (UIElement page in new UIElement[] { dictionaries, reading, general }) Pages.Children.Add(page);
        Nav.SelectedItem = DictionariesItem;
        Show(dictionaries);
    }

    private void OnRouteChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item) return;
        Show((item.Tag as string) switch
        {
            "reading" => reading,
            "general" => general,
            _ => dictionaries,
        });
    }

    private void Show(UIElement page)
    {
        dictionaries.Visibility = page == dictionaries ? Visibility.Visible : Visibility.Collapsed;
        reading.Visibility = page == reading ? Visibility.Visible : Visibility.Collapsed;
        general.Visibility = page == general ? Visibility.Visible : Visibility.Collapsed;
    }
}

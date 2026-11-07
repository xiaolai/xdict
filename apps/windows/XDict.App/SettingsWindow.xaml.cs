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
    private readonly ReadingView reading;
    private readonly SpeechView speech;
    private readonly LookupView lookup;
    private readonly LearningView learning;
    private readonly AIView ai;
    private readonly GeneralView general;
    private readonly SetupView setup;
    private readonly AboutView about;

    public SettingsWindow(LibraryStore store, ServiceClient client, Capture.CaptureController? capture = null,
        ReviewReminders? reminders = null)
    {
        InitializeComponent();
        // Every window follows the saved theme, not only the main window that applied it before opening this one.
        ThemeApplier.Apply(Content as Microsoft.UI.Xaml.FrameworkElement, AppSettings.Load().Theme);
        Title = Strings.Get("settings.title");
        DictionariesItem.Content = Strings.Get("settings.dictionaries");
        ReadingItem.Content = Strings.Get("settings.reading");
        SpeechItem.Content = Strings.Get("settings.speech");
        LookupItem.Content = Strings.Get("settings.lookup");
        LearningItem.Content = Strings.Get("settings.learning");
        AiItem.Content = Strings.Get("settings.ai");
        GeneralItem.Content = Strings.Get("settings.general");
        SetupItem.Content = Strings.Get("settings.setup");
        AboutItem.Content = Strings.Get("settings.about");
        dictionaries = new DictionariesView(store, client, this);
        dictionaries.LibraryChanged += () =>
        {
            LibraryChanged?.Invoke();
            learning?.RefreshLibrary();
        };
        reading = new ReadingView();
        speech = new SpeechView();
        lookup = new LookupView(capture);
        learning = new LearningView(this, store, client, reminders);
        ai = new AIView(this);
        general = new GeneralView();
        setup = new SetupView(store);
        about = new AboutView();
        foreach (UIElement page in new UIElement[]
                 {
                     dictionaries, reading, speech, lookup, learning, ai, general, setup, about,
                 })
            Pages.Children.Add(page);
        Nav.SelectedItem = DictionariesItem;
        Show(dictionaries);
        // Closing cancels what this window started: a second Settings must not build beside the first's import.
        Closed += (_, _) => dictionaries.CancelOperations();
    }

    private void OnRouteChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item) return;
        Show((item.Tag as string) switch
        {
            "reading" => reading,
            "speech" => speech,
            "lookup" => lookup,
            "learning" => learning,
            "ai" => ai,
            "general" => general,
            "setup" => setup,
            "about" => about,
            _ => dictionaries,
        });
    }

    private void Show(UIElement page)
    {
        if (ReferenceEquals(page, setup)) setup.Refresh();
        dictionaries.Visibility = page == dictionaries ? Visibility.Visible : Visibility.Collapsed;
        reading.Visibility = page == reading ? Visibility.Visible : Visibility.Collapsed;
        speech.Visibility = page == speech ? Visibility.Visible : Visibility.Collapsed;
        lookup.Visibility = page == lookup ? Visibility.Visible : Visibility.Collapsed;
        learning.Visibility = page == learning ? Visibility.Visible : Visibility.Collapsed;
        ai.Visibility = page == ai ? Visibility.Visible : Visibility.Collapsed;
        general.Visibility = page == general ? Visibility.Visible : Visibility.Collapsed;
        setup.Visibility = page == setup ? Visibility.Visible : Visibility.Collapsed;
        about.Visibility = page == about ? Visibility.Visible : Visibility.Collapsed;
    }
}

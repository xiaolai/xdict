// The reading history: day groups, the language filter, each card's word/gloss/sentence and its real Open, Remove and
// Restore controls. The drawer's activation is Probe A's; this is the activate-on-use fallback the owner chose when a
// probe's form cannot be shared. The card shows no gloss rather than a guess when the entry cannot be read.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using XDict.Client;
using XDict.Models;
using Windows.Graphics;
using Microsoft.UI.Text;

namespace XDict.App;

public sealed partial class HistoryWindow : Window
{
    private readonly HistorySession session;
    private readonly Action<HistoryCard> openEntry;
    private bool loading = true;
    private bool activated;
    private readonly SemaphoreSlim glossGate = new(4, 4);
    private bool busy;
    private int cards;
    private HistoryCard? removed;

    public HistoryWindow(ServiceClient client, Action<HistoryCard> openEntry)
    {
        InitializeComponent();
        this.openEntry = openEntry;
        session = new HistorySession(client);
        AppWindow.Resize(new SizeInt32((int)Tokens.Size.ReviewWidth, (int)Tokens.Size.ReviewHeight));
        Root.MinHeight = Tokens.Size.ReviewMinHeight;
        ThemeApplier.Follow(Root, this);
        Title = Strings.Get("history.title");
        AutomationProperties.SetLabeledBy(Filter, FilterLabel);
        TitleText.Text = Strings.Get("history.title");
        FilterLabel.Text = Strings.Get("history.filter");
        Filter.Items.Add(Strings.Get("history.filter.all"));
        Filter.SelectedIndex = 0;
        RestoreButton.Content = Strings.Get("history.restore");
        Root.Loaded += OnLoaded;
        // The window is reused: captures and notes that happened since the last look must appear when it comes back.
        Activated += (_, args) =>
        {
            if (!activated) { activated = true; return; }
            if (args.WindowActivationState != WindowActivationState.Deactivated) _ = GuardAsync(LoadAsync);
        };
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (!loading) return;
        loading = false;
        await GuardAsync(LoadAsync);
    }

    private async Task LoadAsync()
    {
        StatusText.Text = "";
        if (!LearningSettings.Load().HistoryEnabled)
        {
            DaysPanel.Children.Clear();
            StatusText.Text = Strings.Get("history.off");
            return;
        }
        await session.LoadAsync();
        BuildFilter();
        Build();
    }

    private void BuildFilter()
    {
        string? selected = Filter.SelectedIndex > 0 ? Filter.SelectedItem as string : null;
        Filter.SelectionChanged -= OnFilterChanged;
        Filter.Items.Clear();
        Filter.Items.Add(Strings.Get("history.filter.all"));
        foreach (string language in session.Cards.Select(card => card.Reading.Language)
                     .Where(language => !string.IsNullOrWhiteSpace(language))
                     .Distinct(StringComparer.OrdinalIgnoreCase)
                     .OrderBy(language => language, StringComparer.OrdinalIgnoreCase))
            Filter.Items.Add(language);
        int index = selected is null ? 0 : Filter.Items.Cast<object>().ToList().IndexOf(selected);
        Filter.SelectedIndex = index < 0 ? 0 : index;
        Filter.SelectionChanged += OnFilterChanged;
    }

    private void OnFilterChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!loading) Build();
    }

    private IReadOnlyList<string>? SelectedLanguages() =>
        Filter.SelectedIndex > 0 && Filter.SelectedItem is string language ? [language] : null;

    private void Build()
    {
        DaysPanel.Children.Clear();
        cards = 0;
        IReadOnlyList<string>? languages = SelectedLanguages();
        foreach (HistoryDay day in session.History.Days)
        {
            List<HistoryCard> visible = day.Cards
                .Where(card => languages is null || languages.Contains(card.Reading.Language))
                .ToList();
            if (visible.Count == 0) continue;
            DaysPanel.Children.Add(new TextBlock
            {
                Text = day.Label,
                FontSize = Tokens.Text.CardMeta,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorTertiaryBrush"],
            });
            foreach (HistoryCard card in visible) DaysPanel.Children.Add(Card(card));
        }
        if (cards == 0) StatusText.Text = Strings.Get("history.empty");
    }

    private Border Card(HistoryCard card)
    {
        var stack = new StackPanel { Spacing = Tokens.Space.Sm };
        HistoryReading reading = card.Reading;
        stack.Children.Add(new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(reading.Surface) ? reading.EntryKey : reading.Surface,
            FontSize = Tokens.Text.CardWord,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        var gloss = new TextBlock
        {
            FontSize = Tokens.Text.CardGloss,
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };
        stack.Children.Add(gloss);
        if (!string.IsNullOrWhiteSpace(reading.Sentence))
        {
            var sentence = new TextBlock
            {
                FontSize = Tokens.Text.CardGloss,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            };
            AddSentence(sentence, reading.Sentence, reading.Span);
            stack.Children.Add(sentence);
        }
        var parts = new List<string> { reading.DictionaryName, reading.Language };
        if (card.Times > 1) parts.Add(Strings.Format("history.times", card.Times));
        stack.Children.Add(new TextBlock
        {
            Text = string.Join(" · ", parts.Where(part => !string.IsNullOrWhiteSpace(part))),
            FontSize = Tokens.Text.CardMeta,
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorTertiaryBrush"],
            TextWrapping = TextWrapping.Wrap,
        });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Tokens.Space.Sm };
        var open = new Button { Content = Strings.Get("history.open"), MinWidth = Tokens.Size.ButtonMinWidth };
        AutomationProperties.SetAutomationId(open, "HistoryOpen-" + cards);
        open.Click += (_, _) => openEntry(card);
        var remove = new Button { Content = Strings.Get("history.remove"), MinWidth = Tokens.Size.ButtonMinWidth };
        AutomationProperties.SetAutomationId(remove, "HistoryRemove-" + cards);
        remove.Click += async (_, _) => await RemoveAsync(card);
        actions.Children.Add(open);
        actions.Children.Add(remove);
        stack.Children.Add(actions);
        _ = LoadGlossAsync(card, gloss);
        var border = new Border
        {
            Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
            CornerRadius = new CornerRadius(Tokens.Radius.L),
            Padding = new Thickness(Tokens.Space.L),
            Width = Tokens.Size.HistoryCard,
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = stack,
        };
        AutomationProperties.SetAutomationId(border, "HistoryCard-" + cards);
        cards++;
        return border;
    }

    private static void AddSentence(TextBlock block, string sentence, HistorySpan? span)
    {
        if (span is not { } range || range.Start > int.MaxValue || range.Len > int.MaxValue)
        {
            block.Text = sentence;
            return;
        }
        int start = (int)range.Start, length = (int)range.Len;
        if (length == 0 || start > sentence.Length || start + length > sentence.Length)
        {
            block.Text = sentence;
            return;
        }
        if (start > 0) block.Inlines.Add(new Run { Text = sentence[..start] });
        block.Inlines.Add(new Run { Text = sentence.Substring(start, length), FontWeight = FontWeights.SemiBold });
        if (start + length < sentence.Length) block.Inlines.Add(new Run { Text = sentence[(start + length)..] });
    }

    private async Task LoadGlossAsync(HistoryCard card, TextBlock target)
    {
        // Bounded: the history can hold hundreds of cards, and one request per card at once exceeds the client's
        // queue and leaves blanks; four at a time keeps the service answering.
        await glossGate.WaitAsync();
        try
        {
            HistoryGloss gloss = await session.GlossAsync(card);
            if (string.IsNullOrWhiteSpace(gloss.Text)) return;
            target.Text = gloss.Text;
            target.Visibility = Visibility.Visible;
        }
        catch (Exception)
        {
            // The edition is no longer open: the card shows no gloss rather than a guess.
        }
        finally
        {
            glossGate.Release();
        }
    }

    private async Task RemoveAsync(HistoryCard card)
    {
        if (busy) return;
        busy = true;
        try
        {
            await session.RemoveAsync(card);
            removed = card;
            await ReloadAsync();
            StatusText.Text = Strings.Get("history.removed");
            RestoreButton.Visibility = Visibility.Visible;
        }
        catch (Exception error)
        {
            StatusText.Text = Describe(error);
        }
        finally
        {
            busy = false;
        }
    }

    private async void OnRestore(object sender, RoutedEventArgs e)
    {
        if (busy || removed is null) return;
        busy = true;
        try
        {
            await session.RestoreAsync(removed);
            removed = null;
            RestoreButton.Visibility = Visibility.Collapsed;
            await ReloadAsync();
            StatusText.Text = Strings.Get("history.restored");
        }
        catch (Exception error)
        {
            StatusText.Text = Describe(error);
        }
        finally
        {
            busy = false;
        }
    }

    private async Task ReloadAsync()
    {
        await session.LoadAsync();
        BuildFilter();
        Build();
    }

    private static string Describe(Exception error) =>
        error is ServiceFailureException failure ? ServiceMessages.For(failure.ErrorType) : error.Message;

    private async Task GuardAsync(Func<Task> work)
    {
        try { await work(); }
        catch (Exception error)
        {
            StatusText.Text = Strings.Format("history.failed", Describe(error));
        }
    }
}

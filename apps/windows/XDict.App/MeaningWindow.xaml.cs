// The meaning pane over one capture: the composed question is the preview, the reader's entry switch gates the entry
// at send, and a validated answer carries its quotes, translation and ungrounded label. Nothing is saved unless the
// reader asks for the note; the sentence and answer are otherwise only in this window.
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using XDict.AI;
using XDict.Client;
using XDict.Contract;
using XDict.Models;
using Windows.Graphics;

namespace XDict.App;

public sealed partial class MeaningWindow : Window
{
    private readonly ServiceClient client;
    private readonly Capture.MeaningRequest request;
    private readonly WindowsCredentialStore keys = new();
    private AISettings settings = new();
    private AIHost? host;
    private AIEntryText? entry;
    private AIComposition? composition;
    private AIAnswer? answer;
    private CancellationTokenSource? inFlight;
    private bool closed;
    private bool busy;
    private bool loaded;

    public MeaningWindow(ServiceClient client, Capture.MeaningRequest request)
    {
        InitializeComponent();
        this.client = client;
        this.request = request;
        AppWindow.Resize(new SizeInt32((int)Tokens.Size.ReviewWidth, (int)Tokens.Size.ReviewHeight));
        Root.MinHeight = Tokens.Size.ReviewMinHeight;
        ThemeApplier.Apply(Root, AppSettings.Load().Theme);
        Title = Strings.Get("meaning.title");
        TitleText.Text = Strings.Get("meaning.title");
        TermText.Text = request.Term;
        MetaText.Text = request.DictionaryName;
        SentenceLabel.Text = Strings.Get("meaning.sentence");
        SentenceText.Text = request.Sentence;
        ModeLabel.Text = Strings.Get("meaning.mode");
        Mode.Items.Add(Strings.Get("meaning.mode.meaning"));
        Mode.Items.Add(Strings.Get("meaning.mode.translate"));
        Mode.Items.Add(Strings.Get("meaning.mode.grammar"));
        Mode.SelectedIndex = 0;
        AskButton.Content = Strings.Get("meaning.ask");
        CancelButton.Content = Strings.Get("meaning.cancel");
        PreviewLabel.Text = Strings.Get("meaning.preview");
        ExplanationLabel.Text = Strings.Get("meaning.explanation");
        QuotesLabel.Text = Strings.Get("meaning.quotes");
        TranslationLabel.Text = Strings.Get("meaning.translation");
        SaveNoteButton.Content = Strings.Get("meaning.saveNote");
        EntryUnavailable.Text = Strings.Get("meaning.entryUnavailable");
        AppWindow.Closing += (_, _) =>
        {
            // Closing must stop the whole lifetime, not only a request that has already started: a load still in
            // flight used to continue into ComposeAsync/AskAsync and send the captured sentence after dismissal.
            closed = true;
            inFlight?.Cancel();
        };
        Root.Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (loaded) return;
        loaded = true;
        await GuardAsync(LoadAsync);
    }

    private async Task LoadAsync()
    {
        settings = AISettings.Load();
        await LoadEntryAsync();
        if (closed) return;
        if (!BuildSource()) return;
        await ComposeAsync();
        if (closed) return;
        if (settings.AskOnOpen && host is not null && !string.IsNullOrWhiteSpace(request.Sentence))
            await AskAsync();
    }

    private async Task LoadEntryAsync()
    {
        try
        {
            Reply reply = await client.CallAsync("entryText", new
            {
                dict = request.Dict,
                entry = new { edition = request.Edition, key = request.Key, occurrence = request.Occurrence },
                view = new
                {
                    baseUrl = "https://xdict.local/",
                    maxBodyBytes = 16 << 20,
                    maxTextBytes = 1 << 20,
                    originalStyle = false,
                },
            });
            if (reply.Error is { } error)
            {
                EntryUnavailable.Visibility = Visibility.Visible;
                StatusText.Text = ServiceMessages.For(error);
                return;
            }
            JsonElement ok = reply.Ok!.Value;
            entry = new AIEntryText(ok.GetProperty("text").GetString() ?? "", ok.GetProperty("complete").GetBoolean(),
                ok.GetProperty("cutAt").GetUInt64());
        }
        catch (Exception error)
        {
            EntryUnavailable.Visibility = Visibility.Visible;
            StatusText.Text = Describe(error);
        }
    }

    private bool BuildSource()
    {
        SourceText.Text = SourceName(settings);
        if (settings.Source == AISourceKind.Off)
        {
            StatusText.Text = Strings.Get("meaning.notConfigured");
            AskButton.IsEnabled = false;
            return false;
        }
        try
        {
            IAISource source = AISourceFactory.Create(settings, keys.Read());
            host = new AIHost(source);
            return true;
        }
        catch (AIProviderException error)
        {
            StatusText.Text = ProviderSentence(error);
            AskButton.IsEnabled = false;
            return false;
        }
    }

    private async void OnModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!loaded) return;
        await GuardAsync(ComposeAsync);
    }

    private async Task ComposeAsync()
    {
        answer = null;
        AnswerPanel.Visibility = Visibility.Collapsed;
        if (host is null) return;
        if (string.IsNullOrWhiteSpace(request.Sentence))
        {
            StatusText.Text = Strings.Get("meaning.entryUnavailable");
            return;
        }
        try
        {
            composition = host.Prepare(Ask(Mode.SelectedIndex), () => AISettings.Load().SendEntryText);
            PreviewText.Text = composition.Text;
            PreviewPanel.Visibility = settings.PreviewBeforeSending ? Visibility.Visible : Visibility.Collapsed;
            UngroundedText.Text = Strings.Get("meaning.ungrounded");
            UngroundedText.Visibility = composition.Ungrounded ? Visibility.Visible : Visibility.Collapsed;
            StatusText.Text = "";
            AskButton.IsEnabled = true;
        }
        catch (Exception error)
        {
            composition = null;
            StatusText.Text = Describe(error);
        }
    }

    private AIAsk Ask(int selected)
    {
        AIMode mode = selected switch
        {
            1 => AIMode.Translate,
            2 => AIMode.ExplainGrammar,
            _ => entry is null ? AIMode.SentenceOnly : AIMode.Grounded,
        };
        return new AIAsk(request.Term, (ulong)Math.Max(request.Start, 0), (ulong)Math.Max(request.Length, 0),
            request.Sentence, settings.Language, mode, entry);
    }

    private async void OnAsk(object sender, RoutedEventArgs e) => await AskAsync();

    private async Task AskAsync()
    {
        if (closed || busy || host is null) return;
        if (composition is null) await ComposeAsync();
        if (closed || composition is null) return;
        busy = true;
        AskButton.IsEnabled = false;
        CancelButton.IsEnabled = true;
        StatusText.Text = Strings.Get("meaning.asking");
        inFlight = new CancellationTokenSource();
        try
        {
            answer = await host.AskAsync(composition, () => AISettings.Load().SendEntryText, inFlight.Token);
            ShowAnswer(answer, composition.Ungrounded);
            StatusText.Text = "";
        }
        catch (OperationCanceledException) { StatusText.Text = Strings.Get("meaning.cancelled"); }
        catch (AIConsentException) { StatusText.Text = Strings.Get("meaning.entrySwitchOff"); }
        catch (AIProviderException error) { StatusText.Text = ProviderSentence(error); }
        catch (AIAnswerException error) { StatusText.Text = Strings.Format("meaning.invalidAnswer", error.Code); }
        catch (AIQuestionException error) { StatusText.Text = Strings.Format("meaning.invalidQuestion", error.Code); }
        catch (Exception error) { StatusText.Text = Describe(error); }
        finally
        {
            busy = false;
            AskButton.IsEnabled = true;
            CancelButton.IsEnabled = false;
            inFlight.Dispose();
            inFlight = null;
        }
    }

    private void OnCancel(object sender, RoutedEventArgs e) => inFlight?.Cancel();

    private void ShowAnswer(AIAnswer value, bool ungrounded)
    {
        string outcomeKey = "meaning.outcome." + value.Outcome;
        OutcomeText.Text = Strings.Get(outcomeKey);
        ExplanationText.Text = value.Explanation;
        ExplanationLabel.Visibility = value.Explanation.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        ExplanationText.Visibility = value.Explanation.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        QuotesPanel.Children.Clear();
        foreach (string quote in value.Quotes)
            QuotesPanel.Children.Add(new TextBlock
            {
                Text = quote,
                FontSize = Tokens.Text.CardGloss,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            });
        QuotesLabel.Visibility = value.Quotes.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        QuotesPanel.Visibility = value.Quotes.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        TranslationText.Text = value.Translation ?? "";
        TranslationLabel.Visibility = value.Translation is null ? Visibility.Collapsed : Visibility.Visible;
        TranslationText.Visibility = value.Translation is null ? Visibility.Collapsed : Visibility.Visible;
        UngroundedText.Visibility = ungrounded ? Visibility.Visible : Visibility.Collapsed;
        SaveNoteButton.Visibility = value.Explanation.Length > 0 || !string.IsNullOrWhiteSpace(value.Translation)
            ? Visibility.Visible : Visibility.Collapsed;
        AnswerPanel.Visibility = Visibility.Visible;
    }

    private async void OnSaveNote(object sender, RoutedEventArgs e)
    {
        if (answer is null || busy) return;
        string content = string.IsNullOrWhiteSpace(answer.Explanation) ? answer.Translation ?? "" : answer.Explanation;
        if (content.Length == 0) return;
        try
        {
            string model = settings.Source switch
            {
                AISourceKind.Http => settings.Model,
                AISourceKind.CodexCli => settings.CodexModel ?? "",
                AISourceKind.ClaudeCli => settings.ClaudeModel ?? "",
                _ => "",
            };
            string provenance = Strings.Format("meaning.noteProvenance", SourceName(settings), model,
                DateTimeOffset.Now.ToString("yyyy-MM-dd"));
            Reply reply = await client.CallAsync("studyNoteAt", new
            {
                entry = new { edition = request.Edition, key = request.Key, occurrence = request.Occurrence },
                text = content + "\n\n" + provenance,
                name = request.DictionaryName,
                stamp = new { at = DateTimeOffset.UtcNow.ToUnixTimeSeconds(), device = DeviceIdentity.Current() },
                operation = "ai-note:" + Guid.NewGuid().ToString("N"),
            });
            StatusText.Text = reply.Error is { } error
                ? Strings.Format("meaning.noteFailed", ServiceMessages.For(error))
                : Strings.Get("meaning.noteSaved");
        }
        catch (Exception error)
        {
            StatusText.Text = Strings.Format("meaning.noteFailed", Describe(error));
        }
    }

    private string SourceName(AISettings chosen) => chosen.Source switch
    {
        AISourceKind.Http => Strings.Get("ai.source.http") + " · " + chosen.Model,
        AISourceKind.CodexCli => Strings.Get("ai.source.codex") + " · " + (chosen.CodexModel ?? ""),
        AISourceKind.ClaudeCli => Strings.Get("ai.source.claude") + " · " + (chosen.ClaudeModel ?? ""),
        _ => Strings.Get("ai.source.off"),
    };

    private static string ProviderSentence(AIProviderException error)
    {
        string key = error.Error switch
        {
            AIProviderError.NotConfigured => "ai.error.notConfigured",
            AIProviderError.NotSignedIn => "ai.error.notSignedIn",
            AIProviderError.Unreachable => "ai.error.unreachable",
            AIProviderError.Redirect => "ai.error.redirect",
            AIProviderError.Authentication => "ai.error.authentication",
            AIProviderError.ModelMissing => "ai.error.modelMissing",
            AIProviderError.Busy => "ai.error.busy",
            AIProviderError.Malformed => "ai.error.malformed",
            AIProviderError.Refused => "ai.error.refused",
            AIProviderError.Truncated => "ai.error.truncated",
            AIProviderError.CliFailed => "ai.error.cliFailed",
            AIProviderError.Timeout => "ai.error.timeout",
            _ => "ai.error.server",
        };
        return Strings.Get(key);
    }

    private static string Describe(Exception error) =>
        error is AIProviderException provider ? ProviderSentence(provider) : error.Message;

    private async Task GuardAsync(Func<Task> work)
    {
        try { await work(); }
        catch (Exception error) { StatusText.Text = Describe(error); }
    }
}

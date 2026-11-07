// Settings ▸ AI: the source, DeepSeek's row or a custom OpenAI-compatible one, the key in Credential Manager, the
// entry switch, the answer language and the two CLI programs. Status checks are local unless the reader asks a
// source; the key is never displayed.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage;
using Windows.Storage.Pickers;
using XDict.AI;
using XDict.Models;

namespace XDict.App;

public sealed partial class AIView : UserControl
{
    private readonly Window owner;
    private readonly WindowsCredentialStore keys = new();
    private AISettings settings;
    private bool loading = true;

    public AIView(Window owner)
    {
        InitializeComponent();
        this.owner = owner;
        settings = AISettings.Load();
        Heading.Text = Strings.Get("settings.ai");
        SourceLabel.Text = Strings.Get("ai.source");
        SourceDetail.Text = Strings.Get("ai.source.detail");
        ProfileLabel.Text = Strings.Get("ai.profile");
        ModelLabel.Text = Strings.Get("ai.model");
        EndpointLabel.Text = Strings.Get("ai.endpoint");
        KeyLabel.Text = Strings.Get("ai.key");
        // A visual label beside a control is not an accessible name: associate the two, so a screen reader reads
        // "Endpoint" rather than only the control's type.
        AutomationProperties.SetLabeledBy(Source, SourceLabel);
        AutomationProperties.SetLabeledBy(Profile, ProfileLabel);
        AutomationProperties.SetLabeledBy(Model, ModelLabel);
        AutomationProperties.SetLabeledBy(Endpoint, EndpointLabel);
        AutomationProperties.SetLabeledBy(KeyBox, KeyLabel);
        AutomationProperties.SetLabeledBy(AnswerLanguage, LanguageLabel);
        KeyBox.PlaceholderText = Strings.Get("ai.key.placeholder");
        SaveKeyButton.Content = Strings.Get("ai.key.save");
        RemoveKeyButton.Content = Strings.Get("ai.key.remove");
        CheckHttpButton.Content = Strings.Get("ai.check");
        EntrySwitch.Header = Strings.Get("ai.entry");
        EntryDetail.Text = Strings.Get("ai.entry.detail");
        LanguageLabel.Text = Strings.Get("ai.language");
        Preview.Header = Strings.Get("ai.preview");
        AskOnOpen.Header = Strings.Get("ai.askOnOpen");
        CodexLabel.Text = Strings.Get("ai.codex");
        ClaudeLabel.Text = Strings.Get("ai.claude");
        BrowseCodexButton.Content = Strings.Get("ai.browse");
        CheckCodexButton.Content = Strings.Get("ai.check");
        BrowseClaudeButton.Content = Strings.Get("ai.browse");
        CheckClaudeButton.Content = Strings.Get("ai.check");

        Source.Items.Add(Strings.Get("ai.source.off"));
        Source.Items.Add(Strings.Get("ai.source.http"));
        Source.Items.Add(Strings.Get("ai.source.codex"));
        Source.Items.Add(Strings.Get("ai.source.claude"));
        Source.SelectedIndex = (int)settings.Source;
        Profile.Items.Add(Strings.Get("ai.profile.deepseek"));
        Profile.Items.Add(Strings.Get("ai.profile.custom"));
        Profile.SelectedIndex = settings.HttpProfile == AIProviderProfiles.CustomId ? 1 : 0;
        AnswerLanguage.Items.Add(Strings.Get("ai.language.en"));
        AnswerLanguage.Items.Add(Strings.Get("ai.language.zh"));
        AnswerLanguage.SelectedIndex = settings.Language == "zh-Hans" ? 1 : 0;
        EntrySwitch.IsOn = settings.SendEntryText;
        Preview.IsOn = settings.PreviewBeforeSending;
        AskOnOpen.IsOn = settings.AskOnOpen;
        UpdateModels();
        Endpoint.Text = settings.Endpoint;
        KeyStatus.Text = keys.Read() is null ? Strings.Get("ai.key.none") : Strings.Get("ai.key.saved");
        UpdatePanels();
        loading = false;
    }

    private void UpdateModels()
    {
        string chosen = settings.Model;
        Model.Items.Clear();
        foreach (string model in settings.Profile.Models) Model.Items.Add(model);
        Model.Text = chosen;
    }

    private void UpdatePanels()
    {
        bool http = settings.Source == AISourceKind.Http;
        bool cli = settings.Source is AISourceKind.CodexCli or AISourceKind.ClaudeCli;
        HttpPanel.Visibility = http ? Visibility.Visible : Visibility.Collapsed;
        CliPanel.Visibility = cli ? Visibility.Visible : Visibility.Collapsed;
        ConsentPanel.Visibility = settings.Source == AISourceKind.Off ? Visibility.Collapsed : Visibility.Visible;
        string codex = settings.CodexConfig()?.Executable ?? Strings.Get("ai.notSet");
        string claude = settings.ClaudeConfig()?.Executable ?? Strings.Get("ai.notSet");
        CodexPathText.Text = codex;
        ClaudePathText.Text = claude;
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
            Status.Text = Strings.Format("ai.saveFailed", error.Message);
        }
    }

    private void OnSourceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || Source.SelectedIndex < 0) return;
        settings = settings with { Source = (AISourceKind)Source.SelectedIndex };
        Save();
        UpdatePanels();
    }

    private void OnProfileChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || Profile.SelectedIndex < 0) return;
        bool custom = Profile.SelectedIndex == 1;
        AIProviderProfile profile = custom ? AIProviderProfiles.Custom : AIProviderProfiles.DeepSeek;
        settings = settings with
        {
            HttpProfile = profile.Id,
            Endpoint = custom ? settings.Endpoint : profile.BaseAddress.ToString(),
            Model = profile.Models.FirstOrDefault() ?? settings.Model,
        };
        UpdateModels();
        Endpoint.Text = settings.Endpoint;
        Save();
    }

    private void OnModelLostFocus(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        settings = settings with { Model = Model.Text.Trim() };
        Save();
    }

    private void OnEndpointLostFocus(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        string text = Endpoint.Text.Trim();
        if (!Uri.TryCreate(text, UriKind.Absolute, out Uri? endpoint) || !AIHttpSource.SecureEndpoint(endpoint))
        {
            Status.Text = Strings.Get("ai.endpointInsecure");
            Endpoint.Text = settings.Endpoint;
            return;
        }
        settings = settings with { Endpoint = text };
        Save();
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || AnswerLanguage.SelectedIndex < 0) return;
        settings = settings with { Language = AnswerLanguage.SelectedIndex == 1 ? "zh-Hans" : "en" };
        Save();
    }

    private void OnEntryToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        settings = settings with { SendEntryText = EntrySwitch.IsOn };
        Save();
    }

    private void OnPreviewToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        settings = settings with { PreviewBeforeSending = Preview.IsOn };
        Save();
    }

    private void OnAskOnOpenToggled(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        settings = settings with { AskOnOpen = AskOnOpen.IsOn };
        Save();
    }

    private void OnSaveKey(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(KeyBox.Password))
        {
            KeyStatus.Text = Strings.Get("ai.key.none");
            return;
        }
        try
        {
            keys.Write(KeyBox.Password);
            KeyBox.Password = "";
            KeyStatus.Text = Strings.Get("ai.key.saved");
        }
        catch (Exception error)
        {
            KeyStatus.Text = Strings.Format("ai.key.failed", error.Message);
        }
    }

    private void OnRemoveKey(object sender, RoutedEventArgs e)
    {
        try
        {
            keys.Write(null);
            KeyStatus.Text = Strings.Get("ai.key.none");
        }
        catch (Exception error)
        {
            KeyStatus.Text = Strings.Format("ai.key.failed", error.Message);
        }
    }

    private void OnCheckHttp(object sender, RoutedEventArgs e)
    {
        try
        {
            string? key = keys.Read();
            settings.HttpConfig(key);
            if (settings.Profile.KeyRequired && string.IsNullOrWhiteSpace(key))
            {
                Status.Text = Strings.Get("ai.check.notConfigured");
                return;
            }
            Status.Text = Strings.Get("ai.check.configured");
        }
        catch (Exception error)
        {
            Status.Text = Strings.Format("ai.check.failed", error.Message);
        }
    }

    private async void OnCheckCodex(object sender, RoutedEventArgs e)
    {
        AICliConfig? config = settings.CodexConfig();
        if (config is null) { Status.Text = Strings.Get("ai.notSet"); return; }
        await CheckCli(new CodexCliSource(config));
    }

    private async void OnCheckClaude(object sender, RoutedEventArgs e)
    {
        AICliConfig? config = settings.ClaudeConfig();
        if (config is null) { Status.Text = Strings.Get("ai.notSet"); return; }
        await CheckCli(new ClaudeCliSource(config));
    }

    private async Task CheckCli(object source)
    {
        try
        {
            AICliStatus status = source switch
            {
                CodexCliSource codex => await codex.CheckAsync(),
                ClaudeCliSource claude => await claude.CheckAsync(),
                _ => throw new AIProviderException(AIProviderError.NotConfigured),
            };
            Status.Text = status.Ready
                ? Strings.Format("ai.check.ready", status.Version ?? "")
                : status.Detail is { } detail && detail.Contains("signed in", StringComparison.OrdinalIgnoreCase)
                    ? Strings.Get("ai.check.notSignedIn")
                    : Strings.Format("ai.check.failed", status.Detail ?? "");
        }
        catch (Exception error)
        {
            Status.Text = Strings.Format("ai.check.failed",
                error is AIProviderException failure ? failure.Message : error.Message);
        }
    }

    private async void OnBrowseCodex(object sender, RoutedEventArgs e) => await Browse(codex: true);
    private async void OnBrowseClaude(object sender, RoutedEventArgs e) => await Browse(codex: false);

    private async Task Browse(bool codex)
    {
        try
        {
            var picker = new FileOpenPicker();
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
            picker.FileTypeFilter.Add(".exe");
            StorageFile? file = await picker.PickSingleFileAsync();
            if (file is null) return;
            settings = codex
                ? settings with { CodexExecutable = file.Path }
                : settings with { ClaudeExecutable = file.Path };
            Save();
            UpdatePanels();
        }
        catch (Exception error)
        {
            Status.Text = Strings.Format("ai.executableFailed", error.Message);
        }
    }
}

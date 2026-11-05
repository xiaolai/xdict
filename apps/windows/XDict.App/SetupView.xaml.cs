// Setup: the Windows rows of the macOS board, read from what the shell actually has. A missing capability is named
// here where the reader would look for it, never silently absent.
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using XDict.AI;
using XDict.Models;

namespace XDict.App;

public sealed partial class SetupView : UserControl
{
    public SetupView(LibraryStore store)
    {
        InitializeComponent();
        Heading.Text = Strings.Get("settings.setup");
        Add("SetupWindows", Strings.Format("setup.windows", Environment.OSVersion.VersionString));
        Add("SetupDictionaries", Strings.Format("setup.dictionaries", store.Dictionaries.Count));
        AISettings ai = AISettings.Load();
        string source = ai.Source switch
        {
            AISourceKind.Http => Strings.Get("ai.source.http"),
            AISourceKind.CodexCli => Strings.Get("ai.source.codex"),
            AISourceKind.ClaudeCli => Strings.Get("ai.source.claude"),
            _ => Strings.Get("ai.source.off"),
        };
        Add("SetupAi", Strings.Format("setup.ai", source));
        Add("SetupHistory", Strings.Format("setup.history",
            LearningSettings.Load().HistoryEnabled ? Strings.Get("setup.on") : Strings.Get("setup.off")));
    }

    private void Add(string id, string sentence)
    {
        var row = new TextBlock
        {
            Text = sentence,
            FontSize = Tokens.Text.Body,
            TextWrapping = Microsoft.UI.Xaml.TextWrapping.Wrap,
        };
        AutomationProperties.SetAutomationId(row, id);
        Rows.Children.Add(row);
    }
}

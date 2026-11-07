// Explore (contract 5): one page of words from the reader's own dictionaries, with the reason a row is there. A
// collocation row is the same list under the collocates operation. Opening a row is the only way to the entry; an
// absent word pack is a said state, never an empty answer pretending to be searched.
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using XDict.Client;
using XDict.Contract;
using XDict.Models;
using Windows.Graphics;

namespace XDict.App;

public sealed partial class ExploreWindow : Window
{
    private static readonly string[] ModeKeys =
        ["endsWith", "fuzzy", "rhyme", "inflections", "derivations", "roots", "synonyms", "antonyms", "collocations"];

    private sealed record RowView(string Word, string Dict, JsonElement Entry, string Reason);

    private readonly ServiceClient client;
    private readonly Func<IReadOnlyList<OpenDictionary>> dictionaries;
    private readonly Action<JsonElement> openEntry;
    private string runText = "";
    private string runMode = "";
    private IReadOnlyList<string> runDicts = [];
    private RequestGeneration? generation;
    private List<RowView> rows = [];
    private uint offset;
    private uint? next;

    public ExploreWindow(ServiceClient client, Func<IReadOnlyList<OpenDictionary>> dictionaries,
        Action<JsonElement> openEntry)
    {
        InitializeComponent();
        this.client = client;
        this.dictionaries = dictionaries;
        this.openEntry = openEntry;
        AppWindow.Resize(new SizeInt32((int)Tokens.Size.ExploreWidth, (int)Tokens.Size.ExploreHeight));
        Root.MinHeight = Tokens.Size.ExploreMinHeight;
        ThemeApplier.Follow(Root, this);
        Title = Strings.Get("explore.title");
        TitleText.Text = Strings.Get("explore.title");
        ScopeLabel.Text = Strings.Get("explore.scope");
        ModeLabel.Text = Strings.Get("explore.mode");
        DistanceLabel.Text = Strings.Get("explore.distance");
        Query.PlaceholderText = Strings.Get("explore.placeholder");
        RunButton.Content = Strings.Get("explore.run");
        PreviousButton.Content = Strings.Get("explore.previous");
        MoreButton.Content = Strings.Get("explore.next");
        OpenButton.Content = Strings.Get("explore.open");
        AutomationProperties.SetName(Query, Strings.Get("explore.query"));
        AutomationProperties.SetName(Scope, Strings.Get("explore.scope"));
        AutomationProperties.SetName(Mode, Strings.Get("explore.mode"));
        AutomationProperties.SetName(Distance, Strings.Get("explore.distance"));
        AutomationProperties.SetName(Results, Strings.Get("explore.resultsList"));
        Scope.Items.Add(Strings.Get("explore.all"));
        foreach (OpenDictionary dictionary in dictionaries()) Scope.Items.Add(dictionary.Name);
        Scope.SelectedIndex = 0;
        foreach (string key in ModeKeys)
        {
            string modeKey = "explore.mode." + key;
            Mode.Items.Add(Strings.Get(modeKey));
        }
        Mode.SelectedIndex = 0;
        Query.Focus(FocusState.Programmatic);
    }

    private void OnScopeChanged(object sender, SelectionChangedEventArgs e) => _ = ReloadAsync();

    private void OnModeChanged(object sender, SelectionChangedEventArgs e)
    {
        string key = SelectedMode();
        DistancePanel.Visibility = key is "fuzzy" or "roots" ? Visibility.Visible : Visibility.Collapsed;
        _ = ReloadAsync();
    }

    private string SelectedMode() =>
        Mode.SelectedIndex >= 0 && Mode.SelectedIndex < ModeKeys.Length ? ModeKeys[Mode.SelectedIndex] : ModeKeys[0];

    private async void OnQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter) return;
        e.Handled = true;
        await ReloadAsync();
    }

    private async void OnRun(object sender, RoutedEventArgs e) => await ReloadAsync();

    private async void OnMore(object sender, RoutedEventArgs e)
    {
        if (next is not { } page) return;
        await LoadAsync(page);
    }

    private async void OnPrevious(object sender, RoutedEventArgs e)
    {
        if (offset == 0) return;
        await LoadAsync(offset > PageSize ? offset - PageSize : 0);
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e) =>
        OpenButton.IsEnabled = Results.SelectedIndex >= 0 && Results.SelectedIndex < rows.Count;

    private void OnOpen(object sender, RoutedEventArgs e)
    {
        int index = Results.SelectedIndex;
        if (index < 0 || index >= rows.Count) return;
        openEntry(rows[index].Entry);
    }

    private const uint PageSize = 50;

    /// <summary>A fresh run captures the reader's query, mode and scope; page turns reuse them, so an edit to the
    /// box cannot be searched from the previous page's offset under the new text.</summary>
    private Task ReloadAsync()
    {
        runText = Query.Text.Trim();
        runMode = SelectedMode();
        runDicts = SelectedDictionaries();
        return LoadAsync(0);
    }

    private async Task LoadAsync(uint from)
    {
        string text = runText;
        if (text.Length == 0) return;
        IReadOnlyList<string> dicts = runDicts;
        if (dicts.Count == 0)
        {
            rows = [];
            next = null;
            RenderAnswer(Strings.Get("explore.noDictionaries"));
            return;
        }
        RequestGeneration mine = client.NewGeneration("explore");
        generation = mine;
        string mode = runMode;
        StatusText.Text = "";
        try
        {
            Reply reply;
            if (mode == "collocations")
            {
                reply = await client.CallAsync("collocates", new { query = text, dicts, limit = PageSize },
                    generation: mine);
            }
            else
            {
                reply = await client.CallAsync("explore", new
                {
                    dicts,
                    mode = ModeBody(mode),
                    text,
                    offset = from,
                    limit = PageSize,
                }, generation: mine);
            }
            if (generation != mine) return;
            if (reply.Error is { } error)
            {
                if (error.GetProperty("type").GetString() == "cancelled") return;
                rows = [];
                next = null;
                RenderAnswer(ServiceMessages.For(error));
                return;
            }
            JsonElement answer = reply.Ok!.Value;
            bool exhausted = false;
            if (mode == "collocations")
            {
                rows = answer.EnumerateArray().Select(CollocationRow).ToList();
                next = null;
            }
            else
            {
                string state = answer.GetProperty("state").GetProperty("type").GetString() ?? "answered";
                rows = answer.GetProperty("rows").EnumerateArray().Select(ExploreRow).ToList();
                next = answer.TryGetProperty("next", out JsonElement more) &&
                       more.ValueKind == JsonValueKind.Number ? more.GetUInt32() : null;
                exhausted = answer.GetProperty("exhausted").GetBoolean();
                if (state == "noData")
                {
                    offset = from;
                    RenderAnswer(Strings.Get("explore.noData"));
                    return;
                }
                if (state == "unknown")
                {
                    offset = from;
                    RenderAnswer(Strings.Get("explore.unknown"));
                    return;
                }
            }
            offset = from;
            RenderAnswer(
                rows.Count == 0 ? Strings.Get("explore.empty") : Strings.Format("explore.results", rows.Count),
                exhausted ? Strings.Get("explore.exhausted") : null);
        }
        catch (OperationCanceledException)
        {
            // A newer query superseded this one.
        }
        finally
        {
            if (generation == mine)
            {
                PreviousButton.IsEnabled = offset > 0;
                MoreButton.IsEnabled = next is not null;
            }
        }
    }

    private void RenderAnswer(string status, string? note = null)
    {
        Results.ItemsSource = rows
            .Select(row => row.Word + " — " + DictionaryName(row.Dict) + " · " + row.Reason)
            .ToList();
        Results.SelectedIndex = -1;
        OpenButton.IsEnabled = false;
        StatusText.Text = note is null ? status : status.Length == 0 ? note : status + " " + note;
    }

    private string DictionaryName(string handle) =>
        dictionaries().FirstOrDefault(dictionary => dictionary.Handle == handle)?.Name ?? handle;

    private IReadOnlyList<string> SelectedDictionaries()
    {
        IReadOnlyList<OpenDictionary> current = dictionaries();
        int index = Scope.SelectedIndex;
        if (index <= 0) return current.Select(dictionary => dictionary.Handle).ToList();
        return index - 1 < current.Count ? [current[index - 1].Handle] : [];
    }

    private object ModeBody(string mode) => mode switch
    {
        "fuzzy" => new { type = "fuzzy", maxDistance = (byte)DistanceValue() },
        "roots" => new { type = "roots", maxDepth = (byte)DistanceValue() },
        _ => new { type = mode },
    };

    private int DistanceValue()
    {
        double value = Distance.Value;
        return double.IsNaN(value) ? 1 : (int)Math.Clamp(Math.Round(value), 1, 3);
    }

    private RowView ExploreRow(JsonElement row)
    {
        JsonElement reason = row.GetProperty("reason");
        string kind = reason.GetProperty("type").GetString() ?? "";
        string label = ReasonLabel(kind, reason);
        return new RowView(row.GetProperty("word").GetString() ?? "", row.GetProperty("dict").GetString() ?? "",
            row.GetProperty("entry").Clone(), label);
    }

    private RowView CollocationRow(JsonElement row)
    {
        string frame = row.GetProperty("frame").GetString() ?? "";
        string frameKey = "explore.frame." + frame;
        string label = Strings.Get("explore.reason.collocation") + " · " + Strings.Get(frameKey);
        return new RowView(row.GetProperty("partner").GetString() ?? "", row.GetProperty("dict").GetString() ?? "",
            row.GetProperty("entry").Clone(), label);
    }

    private static string ReasonLabel(string kind, JsonElement reason)
    {
        if (kind == "spelling" && reason.TryGetProperty("distance", out JsonElement distance))
            return Strings.Format("explore.reason.spelling", distance.GetInt32());
        string reasonKey = "explore.reason." + kind;
        string? label = Strings.Get(reasonKey);
        return string.IsNullOrEmpty(label) || label == reasonKey ? kind : label;
    }
}

// One entry surface per window: the pane, the binding it reads through, the edition and handle it was built for, and
// its private WebView2 folder. The main window and the capture panel replace it the same way; they differ only in
// when, and in what they do after a rebuild.
using Microsoft.UI.Xaml.Controls;
using XDict.Client;
using XDict.Models;

namespace XDict.App;

internal sealed class PaneLease
{
    private string? folder;

    public EntryPane? Pane { get; private set; }
    public DictionaryEntrySource? Source { get; private set; }
    public string? Edition { get; private set; }
    public string? Handle { get; private set; }

    /// <summary>Whether the held pane still serves this edition and this service handle.</summary>
    public bool Matches(string edition, string handle) => Pane is not null && Edition == edition && Handle == handle;

    /// <summary>
    /// Holds a pane for this edition and handle, replacing what was held. `built` says whether the caller must
    /// attach its message and failure handlers: a reused pane already has them.
    /// </summary>
    public async Task<(EntryPane Pane, DictionaryEntrySource Source, bool Built)> EnsureAsync(
        ServiceClient client, string edition, string handle, Action<WebView2> host, ReadingPreferenceStore reading)
    {
        if (Matches(edition, handle)) return (Pane!, Source!, false);
        Reset();
        PaneFactory.Built built = await PaneFactory.CreateAsync(client, edition, handle, host, reading);
        Pane = built.Pane;
        Source = built.Source;
        Edition = edition;
        Handle = handle;
        folder = built.Folder;
        return (Pane, Source, true);
    }

    /// <summary>Drops the pane, its binding and its private folder; a later EnsureAsync builds a fresh one.</summary>
    public void Reset()
    {
        Pane?.Dispose();
        Pane = null;
        Source = null;
        Edition = null;
        Handle = null;
        PaneFactory.Cleanup(folder);
        folder = null;
    }
}

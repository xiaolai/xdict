// One place that builds the entry surface: the WebView2 hosted by the caller, the dictionary binding, the edition's
// reading preference and a private user-data folder. A stable folder held exclusively by a stale process deadlocks
// WebView2 initialization, which is why every pane gets its own; the folder is deleted when its pane is replaced.
using Microsoft.UI.Xaml.Controls;
using XDict.Client;
using XDict.Models;

namespace XDict.App;

internal static class PaneFactory
{
    /// <summary>The pane, the binding it reads through, and the private folder its WebView2 owns.</summary>
    internal sealed record Built(EntryPane Pane, DictionaryEntrySource Source, string Folder);

    internal static async Task<Built> CreateAsync(ServiceClient client, string edition, string handle,
        Action<WebView2> host, ReadingPreferenceStore reading)
    {
        var view = new WebView2();
        host(view);
        var source = new DictionaryEntrySource(client, handle);
        if (!reading.Has(edition))
        {
            AppSettings settings = AppSettings.Load();
            reading.Write(edition, ReadingPreferenceStore.FromSettings(settings, ThemeApplier.Effective(settings.Theme)));
        }
        var pane = new EntryPane(view, source, edition, reading);
        string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "XDict", "entry", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        await pane.InitializeAsync(folder);
        return new Built(pane, source, folder);
    }

    /// <summary>Best effort: a WebView2 still stopping holds its folder, and the startup sweep collects that one.</summary>
    internal static void Cleanup(string? folder)
    {
        if (string.IsNullOrEmpty(folder)) return;
        try { Directory.Delete(folder, true); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Deletes pane folders older than a day, so a folder a stopping WebView2 would not release is not forever.</summary>
    internal static void SweepStale(TimeSpan age)
    {
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDict", "entry");
        if (!Directory.Exists(root)) return;
        foreach (string folder in Directory.EnumerateDirectories(root))
        {
            try
            {
                if (DateTime.UtcNow - Directory.GetLastWriteTimeUtc(folder) > age) Directory.Delete(folder, true);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }
}

// The dictionary list in a window of its own: the labs and the import path use it; the reader reaches the same list
// through Settings ▸ Dictionaries, which hosts the same view (ADR-0012).
using Microsoft.UI.Xaml;
using XDict.Client;
using XDict.Models;

namespace XDict.App;

public sealed class LibraryWindow : Window
{
    private readonly DictionariesView view;

    public LibraryWindow(LibraryStore store, ServiceClient client, bool askLanguages = true)
    {
        Title = Strings.Get("library.title");
        view = new DictionariesView(store, client, this, askLanguages);
        Content = view;
    }

    internal string StatusText => view.StatusText;
    internal Task AddPathsAsync(IReadOnlyList<string> paths) => view.AddPathsAsync(paths);
}

// The reader's library: what they added, where it is, and what the header said. The app owns this file; the service
// owns the editions' registry (ADR-0022 d.9). Paths are the app's, never the service's.
using System.Text.Json;
using System.Text.Json.Serialization;
using XDict.Contract;

namespace XDict.Models;

public enum LibraryRole
{
    Mdx,
    Mdd,
    Sidecar,
}

/// <summary>One file of a package: its stable id, the core's name for it, and where it is now.</summary>
public sealed record LibraryFile(
    string Id, string Name, LibraryRole Role, int Order, string Path, FileIdentity? Identity = null);

/// <summary>A dictionary the reader added. The edition and lineage are the core's; the rest is presentation.</summary>
/// <summary>The library file exists but cannot be read; the shell says so instead of showing an empty list.</summary>
public sealed class LibraryUnreadableException(string message, Exception inner) : Exception(message, inner);

public sealed record LibraryDictionary(
    string Edition,
    string Lineage,
    string Title,
    string DisplayName,
    bool Enabled,
    int Order,
    string SearchLanguage,
    string ExplainLanguage,
    IReadOnlyList<LibraryFile> Files,
    string? HealthJson = null,
    string? StyleJson = null);

/// <summary>What one package's files are, before an import: the MDX, its volumes in order, its loose sidecars.</summary>
public sealed record PackageFiles(
    string Mdx,
    IReadOnlyList<string> Volumes,
    IReadOnlyList<LibrarySidecar> Sidecars,
    IReadOnlyList<int> MissingVolumes);

public sealed record LibrarySidecar(string PackagePath, string Path);

/// <summary>The library file: %LOCALAPPDATA%\XDict\library.json unless another path is given (tests).</summary>
public sealed class LibraryStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
        WriteIndented = true,
    };

    private readonly string path;
    private readonly List<LibraryDictionary> dictionaries;

    private LibraryStore(string path, List<LibraryDictionary> dictionaries)
    {
        this.path = path;
        this.dictionaries = dictionaries;
    }

    public IReadOnlyList<LibraryDictionary> Dictionaries => dictionaries;

    public static string DefaultPath =>
        Environment.GetEnvironmentVariable("XDICT_LIBRARY")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDict", "library.json");

    public static LibraryStore Load(string? path = null)
    {
        path ??= DefaultPath;
        if (!File.Exists(path)) return new LibraryStore(path, []);
        try
        {
            var loaded = JsonSerializer.Deserialize<List<LibraryDictionary>>(File.ReadAllText(path), Options)
                ?? throw new InvalidOperationException("the library file did not decode");
            for (int i = 0; i < loaded.Count; i++)
                if (loaded[i].Order != i)
                    loaded[i] = loaded[i] with { Order = i };
            return new LibraryStore(path, loaded);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        {
            // Other settings files fall back; the library is the reader's list, so it is named, never silently emptied.
            throw new LibraryUnreadableException(path + ": " + error.Message, error);
        }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(dictionaries, Options));
        File.Move(temporary, path, overwrite: true);
    }

    /// <summary>Adds or replaces the dictionary of the same edition; its place is kept when it was known.</summary>
    public LibraryDictionary Add(LibraryDictionary dictionary)
    {
        int existing = dictionaries.FindIndex(item => item.Edition == dictionary.Edition);
        LibraryDictionary added;
        if (existing >= 0)
        {
            added = dictionary with { Order = dictionaries[existing].Order, Enabled = dictionaries[existing].Enabled,
                DisplayName = dictionaries[existing].DisplayName };
            dictionaries[existing] = added;
        }
        else
        {
            added = dictionary with { Order = dictionaries.Count };
            dictionaries.Add(added);
        }
        Save();
        return added;
    }

    public void Remove(string edition)
    {
        if (dictionaries.RemoveAll(item => item.Edition == edition) > 0) { Renumber(); Save(); }
    }

    public void SetEnabled(string edition, bool enabled) => Update(edition, item => item with { Enabled = enabled });

    public void SetLanguages(string edition, string search, string explain) =>
        Update(edition, item => item with { SearchLanguage = search, ExplainLanguage = explain });

    public void SetDisplayName(string edition, string name) =>
        Update(edition, item => item with { DisplayName = name });

    /// <summary>The lineage a join or a split left the edition in.</summary>
    public void SetLineage(string edition, string lineage) =>
        Update(edition, item => item with { Lineage = lineage });

    /// <summary>The details pane's reports, read from the core while the dictionary was open.</summary>
    public void SetReports(string edition, string? healthJson, string? styleJson) =>
        Update(edition, item => item with { HealthJson = healthJson, StyleJson = styleJson });

    /// <summary>Moves the dictionary one place towards the front (-1) or the back (+1).</summary>
    public void Move(string edition, int delta)
    {
        int from = dictionaries.FindIndex(item => item.Edition == edition);
        int to = from + delta;
        if (from < 0 || to < 0 || to >= dictionaries.Count) return;
        (dictionaries[from], dictionaries[to]) = (dictionaries[to], dictionaries[from]);
        Renumber();
        Save();
    }

    private void Update(string edition, Func<LibraryDictionary, LibraryDictionary> change)
    {
        int index = dictionaries.FindIndex(item => item.Edition == edition);
        if (index < 0) return;
        dictionaries[index] = change(dictionaries[index]);
        Save();
    }

    private void Renumber()
    {
        for (int i = 0; i < dictionaries.Count; i++)
            if (dictionaries[i].Order != i)
                dictionaries[i] = dictionaries[i] with { Order = i };
    }
}

/// <summary>A package whose volumes skip a number: importing it would lose the missing volume's pictures and sounds.</summary>
public sealed class PackageIncompleteException(string mdx, IReadOnlyList<int> volumes) : Exception(
    Path.GetFileName(mdx) + " is missing volume " + string.Join(", ", volumes))
{
    public string Mdx { get; } = mdx;
    public IReadOnlyList<int> Volumes { get; } = volumes;
}

/// <summary>Assembling a package from what the reader chose: the MDX, its ordered volumes, the loose files beside it.</summary>
public static class PackageFinder
{
    private const int MaxVolumes = 1000;

    public static IReadOnlyList<string> MdxIn(string folder) =>
        Directory.EnumerateFiles(folder, "*.mdx", SearchOption.TopDirectoryOnly)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase).ToArray();

    /// <summary>
    /// The package of one MDX: <c>name.mdd</c>, <c>name.1.mdd</c>, <c>name.2.mdd</c>… in order, a gap recorded; and
    /// every other regular file in the folder as a sidecar named by its path inside it.
    /// </summary>
    public static PackageFiles Discover(string mdxPath)
    {
        string full = Path.GetFullPath(mdxPath);
        string folder = Path.GetDirectoryName(full) ?? throw new ArgumentException("the MDX has no folder", nameof(mdxPath));
        string stem = Path.GetFileNameWithoutExtension(full);
        var volumes = new List<string>();
        var missing = new List<int>();
        for (int order = 0; order < MaxVolumes; order++)
        {
            string candidate = order == 0 ? Path.Combine(folder, stem + ".mdd")
                : Path.Combine(folder, stem + "." + order + ".mdd");
            if (File.Exists(candidate)) volumes.Add(candidate);
            else if (order > 0 && Enumerable.Range(order + 1, MaxVolumes - order - 1)
                         .Any(next => File.Exists(Path.Combine(folder, stem + "." + next + ".mdd"))))
                missing.Add(order);
            else if (order > 0) break;
        }
        var sidecars = new List<LibrarySidecar>();
        // Recurse without following reparse points: the string/SearchOption overload walks junctions and links out
        // of the folder the reader chose, which the containment rule ReparseGuard enforces forbids.
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint,
        };
        foreach (string file in Directory.EnumerateFiles(folder, "*", options)
                     .OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
        {
            if (file.EndsWith(".mdx", StringComparison.OrdinalIgnoreCase) ||
                file.EndsWith(".mdd", StringComparison.OrdinalIgnoreCase)) continue;
            string relative = Path.GetRelativePath(folder, file).Replace('\\', '/');
            // A loose file at the top joins the package when it shares the dictionary's stem; a subfolder's files
            // (styles, scripts, pictures) are the package's by construction.
            bool nested = relative.Contains('/');
            if (!nested && !string.Equals(Path.GetFileNameWithoutExtension(file), stem, StringComparison.OrdinalIgnoreCase))
                continue;
            sidecars.Add(new LibrarySidecar(relative, file));
        }
        return new PackageFiles(full, volumes, sidecars, missing);
    }

/// <summary>A language pair, and whether the name actually said it: an uncertain pair is the reader's to answer.</summary>
    public sealed record LanguageGuess(string Search, string Explain, bool Certain);

    public static LanguageGuess Guess(string fileName)
    {
        string name = Path.GetFileNameWithoutExtension(fileName);
        if (name.Contains("英汉") || name.Contains("英漢") || name.Contains("English-Chinese", StringComparison.OrdinalIgnoreCase)
            || name.Contains("EN-CN", StringComparison.OrdinalIgnoreCase)) return new("en", "zh-Hans", true);
        if (name.Contains("汉英") || name.Contains("漢英") || name.Contains("Chinese-English", StringComparison.OrdinalIgnoreCase)
            || name.Contains("CN-EN", StringComparison.OrdinalIgnoreCase)) return new("zh-Hans", "en", true);
        if (name.Contains("日汉") || name.Contains("日漢")) return new("ja", "zh-Hans", true);
        if (name.Contains("汉日") || name.Contains("漢日")) return new("zh-Hans", "ja", true);
        if (name.Contains("英英") || name.Contains("English", StringComparison.OrdinalIgnoreCase)) return new("en", "en", true);
        if (name.Contains("汉语") || name.Contains("漢語") || name.Contains("Chinese", StringComparison.OrdinalIgnoreCase))
            return new("zh-Hans", "zh-Hans", true);
        return new("en", "en", false);
    }

    /// <summary>The language pair proposed from the file's name; the reader may edit it.</summary>
    public static (string Search, string Explain) GuessLanguages(string fileName)
    {
        LanguageGuess guess = Guess(fileName);
        return (guess.Search, guess.Explain);
    }
}

/// <summary>
/// The containment rule (AGENTS.md; ADR-0009 d.1's Windows analogue): a file the reader chose is reached through no
/// reparse point, above it or in its place, and it stays under the folder it was found in. Checked at discovery and
/// again before every open, because a link can be put there in between.
/// </summary>
public sealed class ReparseRefusedException(string message) : Exception(message);

public static class ReparseGuard
{
    public static void Check(string path, string root)
    {
        string full = Path.GetFullPath(path);
        string rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!full.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
            throw new ReparseRefusedException($"{full} is not under {rootFull}");
        if ((File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0)
            throw new ReparseRefusedException($"{full} is a reparse point");
        for (var directory = new DirectoryInfo(Path.GetDirectoryName(full)!); directory is not null; directory = directory.Parent)
        {
            if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new ReparseRefusedException($"{directory.FullName} is a reparse point");
            if (string.Equals(directory.FullName.TrimEnd(Path.DirectorySeparatorChar),
                    rootFull.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase)) break;
        }
    }
}

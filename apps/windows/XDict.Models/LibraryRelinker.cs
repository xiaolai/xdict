// A folder the reader moved: the package is found again by the MDX's name and the identity the core recorded, and
// every file of the package moves with it. A copy is not a move: its identity differs and it is not taken.
using XDict.Client;
using XDict.Contract;

namespace XDict.Models;

public static class LibraryRelinker
{
    public static LibraryDictionary? Relink(LibraryDictionary dictionary, string searchRoot)
    {
        LibraryFile? mdx = dictionary.Files.FirstOrDefault(file => file.Role == LibraryRole.Mdx);
        if (mdx is null) return null;
        if (File.Exists(mdx.Path)) return dictionary;
        string oldRoot = Path.GetDirectoryName(mdx.Path) ?? string.Empty;
        string name = Path.GetFileName(mdx.Path);
        // No reparse points and no throw on an unreadable folder: the root may be a whole drive with system folders.
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint,
            IgnoreInaccessible = true,
        };
        foreach (string candidate in Directory.EnumerateFiles(searchRoot, name, options))
        {
            if (!string.Equals(Path.GetFileName(candidate), name, StringComparison.OrdinalIgnoreCase)) continue;
            FileIdentity? identity = FileIdentityReader.Observe(candidate);
            bool matches = mdx.Identity is null ? identity is not null : identity == mdx.Identity;
            if (!matches) continue;
            string newRoot = Path.GetDirectoryName(candidate)!;
            LibraryFile[] files = dictionary.Files.Select(file => file with
            {
                Path = Path.Combine(newRoot, Path.GetRelativePath(oldRoot, file.Path)),
            }).ToArray();
            return dictionary with { Files = files };
        }
        return null;
    }
}

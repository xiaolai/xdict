// Whether a library record's files are still the ones it recorded: present with the identity kept at import, gone,
// or replaced/rewritten (a changed edition the reader must be told about, never a silent re-read).
using XDict.Client;
using XDict.Contract;

namespace XDict.Models;

public enum LibraryFileState
{
    Ok,
    Missing,
    Changed,
}

public sealed record LibraryFileCheck(string Path, LibraryFileState State);

public static class LibraryVerifier
{
    public static IReadOnlyList<LibraryFileCheck> Check(LibraryDictionary dictionary)
    {
        var checks = new List<LibraryFileCheck>(dictionary.Files.Count);
        foreach (LibraryFile file in dictionary.Files)
        {
            if (!File.Exists(file.Path))
            {
                checks.Add(new LibraryFileCheck(file.Path, LibraryFileState.Missing));
                continue;
            }
            FileIdentity? now = FileIdentityReader.Observe(file.Path);
            checks.Add(new LibraryFileCheck(file.Path,
                file.Identity is null || now == file.Identity ? LibraryFileState.Ok : LibraryFileState.Changed));
        }
        return checks;
    }
}

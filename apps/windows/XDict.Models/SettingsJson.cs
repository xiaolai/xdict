// Writing the reader's settings files and the wire's package body, each in one place: three copies of the same
// temporary-then-rename save had drifted, and two copies of the package body could send different shapes.
using System.Text.Json;

namespace XDict.Models;

internal static class SettingsJson
{
    /// <summary>Writes whole to a temporary name and renames it, so a crash never leaves half a file.</summary>
    public static void Write<T>(string path, T value)
    {
        string full = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        string temporary = full + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(value));
            File.Move(temporary, full, true);
        }
        finally
        {
            File.Delete(temporary);
        }
    }
}

internal static class PackageWire
{
    /// <summary>The package body both the importer and the inspector send: the MDX, volumes and sidecars in order.</summary>
    public static object Package(string mdxId, IReadOnlyList<LibraryFile> files) => new
    {
        mdx = new { file = mdxId },
        mdd = files.Where(file => file.Role == LibraryRole.Mdd).OrderBy(file => file.Order)
            .Select(file => new { file = file.Id }).ToArray(),
        sidecars = files.Where(file => file.Role == LibraryRole.Sidecar).OrderBy(file => file.Order)
            .Select(file => new { file = file.Id }).ToArray(),
    };
}

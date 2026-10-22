// The core boundary: the app's output holds no core binary (AGENTS.md; ADR-0003 d.4). The app never links the core;
// the service is the only thing that does. Shown red once by dropping a dummy xdict_core.dll into the app's output.
using Xunit;

public class BoundaryTests
{
    private static readonly string[] Forbidden =
    [
        "xdict_core.dll", "xdict_ffi.dll", "xdict_win_fileid.dll", "xdict_mdx.dll", "xdict_lookup.dll",
        "xdict_identity.dll", "xdict_mmap.dll",
    ];

    [Fact]
    public void TheAppOutputHoldsNoCoreBinary()
    {
        string output = AppOutput();
        string[] found = Directory.EnumerateFiles(output, "*.dll", SearchOption.AllDirectories)
            .Select(Path.GetFileName)
            .Where(name => name is not null && Forbidden.Contains(name, StringComparer.OrdinalIgnoreCase))
            .Select(name => name!)
            .ToArray();
        Assert.Empty(found);
    }

    [Fact]
    public void TheAppOutputCarriesTheAppAndItsService()
    {
        string output = AppOutput();
        Assert.True(File.Exists(Path.Combine(output, "XDict.exe")), "the app's output must carry XDict.exe");
        Assert.True(File.Exists(Path.Combine(output, "XDictService.exe")),
            "the app's output must carry XDictService.exe; the build copies it from the service's cargo target");
    }

    /// <summary>XDICT_APP_OUTPUT names it when the gate sets it; else find it under XDict.App\bin.</summary>
    private static string AppOutput()
    {
        string? named = Environment.GetEnvironmentVariable("XDICT_APP_OUTPUT");
        if (!string.IsNullOrWhiteSpace(named))
        {
            Assert.True(Directory.Exists(named), $"XDICT_APP_OUTPUT names {named}, which is not a directory");
            return named;
        }

        DirectoryInfo? directory = new(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "XDict.slnx")))
            directory = directory.Parent;
        Assert.NotNull(directory);
        string bin = Path.Combine(directory!.FullName, "XDict.App", "bin");
        Assert.True(Directory.Exists(bin), $"build XDict.App first: {bin} does not exist");
        string? outputPath = Directory.EnumerateDirectories(bin, "*", SearchOption.AllDirectories)
            .FirstOrDefault(candidate => File.Exists(Path.Combine(candidate, "XDict.exe")));
        Assert.NotNull(outputPath);
        return outputPath!;
    }
}

// The library's model without a window: discovery, the language guess, the store's order and persistence, and the
// containment rule against a junction (the Windows reparse case that needs no privilege).
using System.Diagnostics;
using XDict.Models;
using Xunit;

public class LibraryTests
{
    [Fact]
    public void AVolumesGapIsReportedAndSidecarsAreNamedByTheirPath()
    {
        string root = NewFolder();
        try
        {
            File.WriteAllText(Path.Combine(root, "foo.mdx"), "x");
            File.WriteAllText(Path.Combine(root, "foo.mdd"), "x");
            File.WriteAllText(Path.Combine(root, "foo.1.mdd"), "x");
            File.WriteAllText(Path.Combine(root, "foo.3.mdd"), "x");
            Directory.CreateDirectory(Path.Combine(root, "styles"));
            File.WriteAllText(Path.Combine(root, "styles", "main.css"), "x");
            PackageFiles package = PackageFinder.Discover(Path.Combine(root, "foo.mdx"));
            Assert.Equal(new[] { Path.Combine(root, "foo.mdd"), Path.Combine(root, "foo.1.mdd"), Path.Combine(root, "foo.3.mdd") },
                package.Volumes);
            Assert.Equal(new[] { 2 }, package.MissingVolumes);
            Assert.Contains(package.Sidecars, sidecar => sidecar.PackagePath == "styles/main.css");
            Assert.DoesNotContain(package.Sidecars, sidecar => sidecar.Path.EndsWith(".mdd", StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Theory]
    [InlineData("牛津英汉双解.mdx", "en", "zh-Hans")]
    [InlineData("汉英大词典.mdx", "zh-Hans", "en")]
    [InlineData("OALD 10th.mdx", "en", "en")]
    [InlineData("现代汉语词典.mdx", "zh-Hans", "zh-Hans")]
    public void TheLanguagePairIsProposedFromTheName(string name, string search, string explain)
    {
        Assert.Equal((search, explain), PackageFinder.GuessLanguages(name));
    }

    [Fact]
    public void TheStoreKeepsOrderAndEditsAcrossALoad()
    {
        string folder = NewFolder();
        try
        {
            string path = Path.Combine(folder, "library.json");
            LibraryStore store = LibraryStore.Load(path);
            LibraryDictionary first = Dictionary("edition-a", "A");
            LibraryDictionary second = Dictionary("edition-b", "B");
            store.Add(first);
            store.Add(second);
            store.Add(Dictionary("edition-a", "A later title"));
            Assert.Equal(2, store.Dictionaries.Count);
            store.Move("edition-b", -1);
            Assert.Equal("edition-b", store.Dictionaries[0].Edition);
            store.SetEnabled("edition-a", false);
            store.SetLanguages("edition-b", "en", "zh-Hans");
            store.SetDisplayName("edition-a", "Alpha");
            LibraryStore loaded = LibraryStore.Load(path);
            Assert.Equal(new[] { "edition-b", "edition-a" }, loaded.Dictionaries.Select(item => item.Edition));
            Assert.False(loaded.Dictionaries[1].Enabled);
            Assert.Equal("Alpha", loaded.Dictionaries[1].DisplayName);
            Assert.Equal("zh-Hans", loaded.Dictionaries[0].ExplainLanguage);
            Assert.Equal(new[] { 0, 1 }, loaded.Dictionaries.Select(item => item.Order));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void AFileReachedThroughAJunctionIsRefused()
    {
        if (!OperatingSystem.IsWindows()) return;
        string root = NewFolder();
        string outside = NewFolder();
        string link = Path.Combine(root, "link");
        try
        {
            Directory.CreateDirectory(Path.Combine(outside, "styles"));
            string file = Path.Combine(outside, "styles", "main.css");
            File.WriteAllText(file, "x");
            var start = new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{link}\" \"{outside}\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardError = true,
                RedirectStandardOutput = true,
            };
            using (Process process = Process.Start(start)!)
            {
                process.WaitForExit();
                Assert.True(process.ExitCode == 0, "mklink /J is refused on this host");
            }
            Assert.Throws<ReparseRefusedException>(() => ReparseGuard.Check(Path.Combine(link, "styles", "main.css"), root));
        }
        finally
        {
            var remove = new ProcessStartInfo("cmd.exe", $"/c rmdir \"{link}\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using (Process process = Process.Start(remove)!) process.WaitForExit();
            Directory.Delete(root, recursive: true);
            Directory.Delete(outside, recursive: true);
        }
    }

    private static LibraryDictionary Dictionary(string edition, string title) => new(
        edition, "lineage-" + edition, title, title, true, 0, "en", "en",
        [new LibraryFile("id-" + edition, "id-" + edition, LibraryRole.Mdx, 0, @"C:\dict\a.mdx")]);

    private static string NewFolder()
    {
        string folder = Path.Combine(Path.GetTempPath(), "xdict-library-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        return folder;
    }
}

using XDict.Models;
using Xunit;

public class ReadingPreferenceTests
{
    [Fact]
    public void RelaunchRestoresTheEditionWithoutChangingAnotherDictionary()
    {
        string directory = Path.Combine(Path.GetTempPath(), "xdict-preferences-" + Guid.NewGuid());
        string path = Path.Combine(directory, "reading.json");
        try
        {
            new ReadingPreferenceStore(path).Write("edition-a", new(1.5, "dark", true));
            var relaunched = new ReadingPreferenceStore(path);
            Assert.Equal(new ReadingPreferences(1.5, "dark", true), relaunched.Read("edition-a"));
            Assert.Equal(new ReadingPreferences(), relaunched.Read("edition-b"));
            relaunched.Write("edition-b", new(2, "light"));
            Assert.Equal(new ReadingPreferences(1.5, "dark", true), new ReadingPreferenceStore(path).Read("edition-a"));
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
    [Fact]
    public void CorruptStorageAndInvalidValuesKeepTheViewUsable()
    {
        string path = Path.Combine(Path.GetTempPath(), "xdict-preferences-" + Guid.NewGuid() + ".json");
        try
        {
            File.WriteAllText(path, "{");
            Assert.Equal(new ReadingPreferences(), new ReadingPreferenceStore(path).Read("edition"));
            new ReadingPreferenceStore(path).Write("edition", new(double.NaN, "injected", false));
            Assert.Equal(new ReadingPreferences(), new ReadingPreferenceStore(path).Read("edition"));
            Assert.Equal(3, new ReadingPreferences(42).Validated().Zoom);
        }
        finally { File.Delete(path); }
    }
}

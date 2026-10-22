// The string gate: both languages carry the same keys, none empty. A missing key fails here before the app starts.
using XDict.Models;
using Xunit;

public class StringsTests
{
    [Fact]
    public void EveryLanguageCarriesEveryKey()
    {
        Assert.Equal(2, Strings.Languages.Count);
        Assert.NotEmpty(Strings.Keys);
        foreach (string language in Strings.Languages)
            foreach (string key in Strings.Keys)
                Assert.False(string.IsNullOrWhiteSpace(Strings.Get(key, language)), $"{language} has no {key}");
    }

    [Fact]
    public void ChineseIsChinese()
    {
        foreach (string key in Strings.Keys)
            Assert.Contains(Strings.Get(key, Strings.SimplifiedChinese), c => c > 0x7F || key == "app.title");
    }

    [Fact]
    public void TheVersionsSentenceFillsEveryPlaceholder()
    {
        string line = Strings.Format("app.versions", "0.0.6", 1u, 2u, 1u);
        Assert.Contains("0.0.6", line);
        Assert.DoesNotContain("{0}", line);
    }
}

// The SSML the shell sends and the voice it picks: IPA as a phoneme, escaping, the reader's accent, and Chinese.
using XDict.Models;
using Xunit;

public class SpeechTextTests
{
    [Fact]
    public void IpaBecomesAPhonemeAndTextIsEscaped()
    {
        string ssml = SpeechText.Ssml("a<b&c", "rɪˈkɔːrd", "en-US");
        Assert.Contains("alphabet=\"ipa\"", ssml);
        Assert.Contains("ph=\"rɪˈkɔːrd\"", ssml);
        Assert.Contains("a&lt;b&amp;c", ssml);
        Assert.DoesNotContain("<b", ssml);
    }

    [Fact]
    public void WithoutIpaTheWordIsSpokenAsWritten()
    {
        string ssml = SpeechText.Ssml("record", null, "en-GB");
        Assert.DoesNotContain("phoneme", ssml);
        Assert.Contains(">record<", ssml);
        Assert.Contains("xml:lang=\"en-GB\"", ssml);
    }

    [Fact]
    public void TheAccentChoosesTheVoiceAndChineseSpeaksChinese()
    {
        var voices = new[]
        {
            ("David", "en-US"), ("Zira", "en-US"), ("George", "en-GB"), ("Huihui", "zh-CN"),
        };
        Assert.Equal("George", SpeechText.ChooseVoice(voices, "en", "uk"));
        Assert.Equal("David", SpeechText.ChooseVoice(voices, "en", "us"));
        Assert.Contains(SpeechText.ChooseVoice(voices, "en"), new[] { "David", "Zira", "George" });
        Assert.Equal("Huihui", SpeechText.ChooseVoice(voices, "zh-Hans"));
        Assert.Null(SpeechText.ChooseVoice(voices, "fr"));
    }
}

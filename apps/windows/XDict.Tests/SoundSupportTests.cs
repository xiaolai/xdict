// A recording's three outcomes and their distinct sentences: playable, Speex (unsupported), missing.
using XDict.Models;
using Xunit;

public class SoundSupportTests
{
    [Theory]
    [InlineData("run.mp3", true, "audio/mpeg", SoundKind.Playable)]
    [InlineData("run.ogg", true, "audio/ogg", SoundKind.Playable)]
    [InlineData("run.spx", true, "audio/speex", SoundKind.Unsupported)]
    [InlineData("run.bin", true, "application/octet-stream", SoundKind.Unsupported)]
    [InlineData("run.mp3", false, null, SoundKind.Missing)]
    public void ARecordingIsClassifiedBeforePlayback(string path, bool found, string? mime, SoundKind kind)
    {
        Assert.Equal(kind, SoundSupport.Classify(path, found, mime).Kind);
    }

    [Fact]
    public void MissingAndUnsupportedAreDifferentSentencesInBothLanguages()
    {
        foreach (string language in new[] { "en", "zh-Hans" })
        {
            string missing = SoundSupport.Sentence(SoundKind.Missing, language);
            string unsupported = SoundSupport.Sentence(SoundKind.Unsupported, language);
            Assert.False(string.IsNullOrWhiteSpace(missing));
            Assert.False(string.IsNullOrWhiteSpace(unsupported));
            Assert.NotEqual(missing, unsupported);
        }
    }
}

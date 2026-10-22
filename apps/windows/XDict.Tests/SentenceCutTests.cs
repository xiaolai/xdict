using XDict.Models;
using Xunit;

public class SentenceCutTests
{
    [Fact]
    public void AWordInsideASentenceTakesThatSentence()
    {
        const string text = "Please hold the door. Then run.";
        SentenceCut.Sentence? sentence = SentenceCut.Around(text, text.IndexOf("hold", StringComparison.Ordinal), 4);
        Assert.NotNull(sentence);
        Assert.Equal("Please hold the door.", sentence.Text);
        Assert.Equal(7, sentence.TermStart);
        Assert.Equal(4, sentence.TermLength);
        Assert.False(sentence.CutStart);
        Assert.False(sentence.CutEnd);
    }

    [Fact]
    public void TheEdgesAndTheLastSentence()
    {
        const string text = "Run. Please hold the door";
        SentenceCut.Sentence? first = SentenceCut.Around(text, 0, 3);
        Assert.NotNull(first);
        Assert.Equal("Run.", first.Text);
        SentenceCut.Sentence? last = SentenceCut.Around(text, text.IndexOf("door", StringComparison.Ordinal), 4);
        Assert.NotNull(last);
        Assert.Equal("Please hold the door", last.Text);
    }

    [Fact]
    public void ClosersBelongToTheSentence()
    {
        const string text = "He said \"hold.\" Then left.";
        SentenceCut.Sentence? sentence = SentenceCut.Around(text, text.IndexOf("hold", StringComparison.Ordinal), 4);
        Assert.NotNull(sentence);
        Assert.Equal("He said \"hold.\"", sentence.Text);
    }

    [Fact]
    public void ChinesePunctuationEndsASentenceWithoutSpaces()
    {
        const string text = "请按住门。然后跑。";
        SentenceCut.Sentence? sentence = SentenceCut.Around(text, text.IndexOf("门", StringComparison.Ordinal), 1);
        Assert.NotNull(sentence);
        Assert.Equal("请按住门。", sentence.Text);
    }

    [Fact]
    public void APhraseAcrossSentencesTakesTheWholeRun()
    {
        const string text = "Please hold the door. Then run fast.";
        SentenceCut.Sentence? sentence = SentenceCut.Around(text, text.IndexOf("door", StringComparison.Ordinal), 11);
        Assert.NotNull(sentence);
        Assert.Equal(text, sentence.Text);
    }

    [Fact]
    public void AParagraphOverTheCeilingIsCutAroundTheTerm()
    {
        string text = new string('a', 3000) + "hold" + new string('b', 3000);
        SentenceCut.Sentence? sentence = SentenceCut.Around(text, 3000, 4);
        Assert.NotNull(sentence);
        Assert.Equal(1000, sentence.Text.Length);
        Assert.True(sentence.CutStart);
        Assert.True(sentence.CutEnd);
        Assert.Equal(4, sentence.TermLength);
        Assert.Equal("hold", sentence.Text.Substring(sentence.TermStart, sentence.TermLength));
    }

    [Fact]
    public void ACutNeverSplitsASurrogatePair()
    {
        string text = new string('a', 996) + "😀" + new string('b', 3000) + "hold" + new string('c', 10);
        SentenceCut.Sentence? sentence = SentenceCut.Around(text, 996 + 2 + 3000, 4);
        Assert.NotNull(sentence);
        Assert.True(sentence.Text.Length <= 1000);
        Assert.False(char.IsLowSurrogate(sentence.Text[0]));
        Assert.Equal("hold", sentence.Text.Substring(sentence.TermStart, sentence.TermLength));
    }

    [Fact]
    public void ATermTooLongForTheCeilingOrARangeOutsideIsRefused()
    {
        Assert.Null(SentenceCut.Around("short text", 0, 11));
        Assert.Null(SentenceCut.Around("short", 2, 10));
        Assert.Null(SentenceCut.Around(new string('x', 1200), 0, 1100));
        Assert.Null(SentenceCut.Around("😀 hold", 1, 4)); // starts inside the pair
    }
}

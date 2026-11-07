// The meaning session's model: the preview is the sent bytes, consent at send downgrades or refuses, and a validated
// answer carries its quotes and ungrounded label. A fake source stands in for every provider.
using XDict.AI;
using Xunit;

public class AIHostTests
{
    private sealed class Fake(string answer) : IAISource
    {
        private int calls;
        public int Calls => Volatile.Read(ref calls);
        public string? Sent { get; private set; }
        public AIMode? Mode { get; private set; }

        public Task<string> AskAsync(AIMode mode, string composed, CancellationToken cancellation = default)
        {
            Interlocked.Increment(ref calls);
            Mode = mode;
            Sent = composed;
            return Task.FromResult(answer);
        }
    }

    /// <summary>A source whose one ask never completes until the test says so: cancellation has somewhere to land.</summary>
    private sealed class Pending : IAISource
    {
        private readonly TaskCompletionSource<string> completion =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int Calls { get; private set; }

        public Task<string> AskAsync(AIMode mode, string composed, CancellationToken cancellation = default)
        {
            Calls++;
            Started.TrySetResult();
            return completion.Task.WaitAsync(cancellation);
        }
    }

    private static readonly AIEntryText Entry = new("1. to hold; to keep", true, 0);

    [Fact]
    public async Task ThePreviewIsExactlyWhatTheSourceReceives()
    {
        var source = new Fake("{\"outcome\":\"matched\",\"quotes\":[\"to hold\"],\"explanation\":\"Here, hold means keep.\"}");
        var host = new AIHost(source);
        var ask = new AIAsk("hold", 7, 4, "Please hold the door.", "en", AIMode.Grounded, Entry,
            Template: "{term} in: {sentence}\n{entry}");
        AIComposition composition = host.Prepare(ask, () => true);
        AIAnswer answer = await host.AskAsync(composition, () => true);
        Assert.Equal("matched", answer.Outcome);
        Assert.Equal(["to hold"], answer.Quotes);
        Assert.False(answer.Ungrounded);
        Assert.Equal(composition.Text, source.Sent);
        Assert.Equal(AIMode.Grounded, source.Mode);
        // One question is one provider call: a retry or a duplicated send would be visible here.
        Assert.Equal(1, source.Calls);
    }

    [Fact]
    public async Task OneQuestionIsOneProviderCallAndCancellationReachesIt()
    {
        var source = new Pending();
        var host = new AIHost(source);
        var ask = new AIAsk("hold", 7, 4, "Please hold the door.", "en", AIMode.Grounded, Entry,
            Template: "{term} in: {sentence}\n{entry}");
        AIComposition composition = host.Prepare(ask, () => true);
        using var cancellation = new CancellationTokenSource();
        Task<AIAnswer> asked = host.AskAsync(composition, () => true, cancellation.Token);
        await source.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, source.Calls);
        cancellation.Cancel();
        // The provider's own cancellation token is the caller's: the call stops with it, and nothing retries.
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => asked);
        Assert.Equal(1, source.Calls);
    }

    [Fact]
    public async Task ConsentRevokedAfterPrepareRefusesToSend()
    {
        // Consent can change between the preview and the send: the send checks it again, before the provider is called.
        var grounded = new Fake("{}");
        var host = new AIHost(grounded);
        AIComposition composition = host.Prepare(
            new AIAsk("hold", 7, 4, "Please hold the door.", "en", AIMode.Grounded, Entry,
                Template: "{term} in: {sentence}\n{entry}"), () => true);
        await Assert.ThrowsAsync<AIConsentException>(() => host.AskAsync(composition, () => false));
        Assert.Equal(0, grounded.Calls);

        var sense = new Fake("{}");
        var explaining = new AIHost(sense);
        AIComposition explained = explaining.Prepare(
            new AIAsk("hold", 7, 4, "Please hold.", "en", AIMode.ExplainSense, Entry,
                new AISense(1, 0, (ulong)"1. to hold".Length, "1. to hold", "1", "verb", true),
                Template: "{term} {sentence} {entry} {sense}"), () => true);
        await Assert.ThrowsAsync<AIConsentException>(() => explaining.AskAsync(explained, () => false));
        Assert.Equal(0, sense.Calls);
    }

    [Fact]
    public async Task WithTheEntrySwitchOffGroundedBecomesSentenceOnlyAndIsLabelledUngrounded()
    {
        var source = new Fake(
            "{\"outcome\":\"explanationOnly\",\"quotes\":[],\"explanation\":\"Here it means keep.\"}");
        var host = new AIHost(source);
        var ask = new AIAsk("hold", 7, 4, "Please hold the door.", "en", AIMode.Grounded, Entry,
            Template: "{term} in: {sentence}");
        AIComposition composition = host.Prepare(ask, () => false);
        Assert.Equal(AIMode.SentenceOnly, composition.Mode);
        Assert.True(composition.Ungrounded);
        Assert.DoesNotContain("to hold", composition.Text);
        AIAnswer answer = await host.AskAsync(composition, () => false);
        Assert.True(answer.Ungrounded);
        Assert.Equal(AIMode.SentenceOnly, source.Mode);
    }

    [Fact]
    public void WithTheEntrySwitchOffExplainSenseIsRefused()
    {
        var sense = new AISense(1, 0, 8, "1. to hold", "1", "verb", true);
        var ask = new AIAsk("hold", 7, 4, "Please hold.", "en", AIMode.ExplainSense, Entry, sense,
            Template: "{term} {sentence} {entry} {sense}");
        Assert.Throws<AIConsentException>(() => new AIHost(new Fake("{}")).Prepare(ask, () => false));
    }

    [Fact]
    public async Task AnInvalidAnswerIsNeverPresentedAsPlausible()
    {
        var source = new Fake("{\"outcome\":\"matched\",\"quotes\":[\"not in the entry\"],\"explanation\":\"x\"}");
        var ask = new AIAsk("hold", 7, 4, "Please hold.", "en", AIMode.Grounded, Entry,
            Template: "{term} {sentence} {entry}");
        AIComposition composition = new AIHost(source).Prepare(ask, () => true);
        var error = await Assert.ThrowsAsync<AIAnswerException>(() =>
            new AIHost(source).AskAsync(composition, () => true));
        Assert.Equal("answer.quote.notFound", error.Code);
    }

    [Fact]
    public void EveryDefaultTemplateIsEmbeddedForBothLanguagesAndAllModes()
    {
        string[] modes = ["grounded", "sentenceOnly", "explainSense", "translate", "explainGrammar"];
        foreach (string language in AITemplates.Languages)
            foreach (string mode in modes)
                Assert.Contains($"XDict.AI.defaults.{language}.{mode}.txt", AITemplates.EmbeddedNames());
        Assert.Contains("{term}", AITemplates.Default("en", AIMode.Grounded));
        Assert.Contains("{term}", AITemplates.Default("zh-Hans", AIMode.Grounded));
    }
}

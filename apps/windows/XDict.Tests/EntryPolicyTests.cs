using System.Text.Json;
using XDict.Models;
using Xunit;

public class EntryPolicyTests
{
    private const string Document = "xdict://d/entry/document-one";
    [Theory]
    [InlineData("xdict://d/entry/word", EntryRoute.Document)]
    [InlineData("xdict://d/r/a.css?version=1", EntryRoute.Resource)]
    [InlineData("xdict://d/sound/a.mp3", EntryRoute.Sound)]
    [InlineData("xdict://d/blocked/http%3A%2F%2Fevil.invalid", EntryRoute.Blocked)]
    [InlineData("https://xdict.local/entry/word", EntryRoute.Refused)]
    [InlineData("xdict://d.evil.invalid/r/a", EntryRoute.Refused)]
    [InlineData("xdict://user@d/r/a", EntryRoute.Refused)]
    [InlineData("xdict://d:42/r/a", EntryRoute.Refused)]
    [InlineData("file:///C:/secret", EntryRoute.Refused)]
    [InlineData("data:text/html,evil", EntryRoute.Refused)]
    [InlineData("xdict://d/unknown/x", EntryRoute.Refused)]
    [InlineData("xdict://d/r/", EntryRoute.Refused)]
    public void OnlyOwnedRoutesAreServed(string url, EntryRoute expected) => Assert.Equal(expected, EntryPolicy.Route(url));

    [Fact]
    public void NavigationAllowsOnlyTheRequestedDocumentItsFragmentAndInheritedFrames()
    {
        Assert.True(EntryPolicy.Navigation(Document, Document, true));
        Assert.True(EntryPolicy.Navigation(Document + "#sense", Document, true));
        Assert.True(EntryPolicy.Navigation("about:srcdoc", Document, false));
        Assert.False(EntryPolicy.Navigation("xdict://d/r/evil.html", Document, true));
        Assert.False(EntryPolicy.Navigation("https://example.invalid/", Document, true));
        Assert.False(EntryPolicy.Navigation(Document, Document, false));
        Assert.Equal(EntryRoute.Refused, EntryPolicy.Route("xdict://d/r/a", "POST"));
    }

    [Fact]
    public void EveryBridgeKindRejectsForgedAndStaleMessages()
    {
        foreach (string kind in new[] { "word", "link", "sound" })
        {
            string value = kind == "word" ? "dictionary reader" : "xdict://d/entry/word";
            string Message(string nonce, ulong generation) => JsonSerializer.Serialize(new { kind, value, nonce, generation });
            Assert.NotNull(EntryPolicy.Message(Message("n", 7), Document, Document, "n", 7));
            Assert.Null(EntryPolicy.Message(Message("forged", 7), Document, Document, "n", 7));
            Assert.Null(EntryPolicy.Message(Message("n", 6), Document, Document, "n", 7));
            Assert.Null(EntryPolicy.Message(Message("n", 7), "xdict://d/entry/old", Document, "n", 7));
        }
        Assert.Null(EntryPolicy.Message("{", Document, Document, "n", 7));
        Assert.Null(EntryPolicy.Message(new string('x', 4097), Document, Document, "n", 7));
        Assert.Null(EntryPolicy.Message("{\"kind\":\"ai\",\"value\":\"send\",\"nonce\":\"n\",\"generation\":7}", Document, Document, "n", 7));
        Assert.Null(EntryPolicy.Message("{\"kind\":\"link\",\"value\":\"https://evil.invalid/\",\"nonce\":\"n\",\"generation\":7}", Document, Document, "n", 7));
    }
}

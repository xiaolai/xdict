// Five visits, back and forward exactly, a return to the first, and a new visit after going back discarding the
// forward ones.
using System.Text.Json;
using XDict.Models;
using Xunit;

public class TrailTests
{
    [Fact]
    public void FiveVisitsWalkBackForwardAndReturnExactly()
    {
        var trail = new Trail();
        for (int word = 0; word < 5; word++) trail.Push(Visit(word));
        Assert.Equal(5, trail.Count);
        Assert.Equal("w4", trail.Current!.Query);

        for (int step = 3; step >= 0; step--) Assert.Equal($"w{step}", trail.Back()!.Query);
        Assert.Equal("w0", trail.Current!.Query);
        Assert.Null(trail.Back());
        Assert.Equal("w1", trail.Forward()!.Query);
        Assert.Equal("w2", trail.Forward()!.Query);
        Assert.Equal("w0", trail.Return()!.Query);
        Assert.False(trail.CanReturn);

        for (int step = 1; step <= 4; step++) trail.Forward();
        Assert.Equal("w4", trail.Current!.Query);
        trail.Back();
        trail.Back();
        trail.Push(Visit(9));
        Assert.Equal("w9", trail.Current!.Query);
        Assert.Equal(4, trail.Count); // w0, w1, w2, w9: the forward visits were discarded
        Assert.False(trail.CanForward);
    }

    private static Visit Visit(int word) => new(
        "edition", JsonSerializer.SerializeToElement(new { key = "w" + word }), "w" + word);
}

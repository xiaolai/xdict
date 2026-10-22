using XDict.Models;
using Xunit;

public class EntryDisplayOptionsTests
{
    private static EntryDisplayOptions Catalogue => new(1,
        [new("pronunciation", "data-xdict-opt-pronunciation", ["ipa", "respell", "both"], "ipa")], "body{}");
    [Fact]
    public void EveryDeclaredDefaultIsSetAndOnlyListedReaderValuesApply()
    {
        Assert.Equal("ipa", Catalogue.Resolve(null).Single()[1]);
        Assert.Equal("both", Catalogue.Resolve(new Dictionary<string, string> { ["pronunciation"] = "both" }).Single()[1]);
        Assert.Equal("ipa", Catalogue.Resolve(new Dictionary<string, string> { ["pronunciation"] = "injected" }).Single()[1]);
    }
    [Fact]
    public void AServiceReplyCannotTurnAnOptionIntoAHostAttribute()
    {
        var unsafeCatalogue = Catalogue with { Options = [new("pronunciation", "onclick", ["ipa"], "ipa")] };
        Assert.Throws<InvalidDataException>(() => unsafeCatalogue.Resolve(null));
    }
}

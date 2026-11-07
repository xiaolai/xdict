// The service's typed refusals through the production client and pipe: a contract it does not speak, and an
// operation it does not have. CONTRACT.md §2, §3, §6.
using System.Text.Json;
using XDict.Client;
using XDict.Contract;
using Xunit;
using XDict.Models;

public class ContractMismatchTests
{
    [Theory]
    [InlineData(-1)] // Wire.Version - 1: an older contract
    [InlineData(1)]  // Wire.Version + 1: a newer one
    public void AnOlderOrNewerContractIsRefusedTyped(int offset)
    {
        // Both directions, each named from Wire.Version: 999 was a newer number, so the "older" case was never sent.
        uint foreign = unchecked((uint)(Wire.Version + offset));
        using ServiceClient client = Start();
        Reply reply = client.CallWithContract(foreign, "versions", null);
        Assert.NotNull(reply.Error);
        Assert.Equal("contractMismatch", reply.Error!.Value.GetProperty("type").GetString());
        Assert.Equal(foreign, reply.Error.Value.GetProperty("contract").GetUInt32());
        Assert.Equal(Wire.Version, reply.Error.Value.GetProperty("service").GetUInt32());
        Assert.Equal(client.LastRequestId, reply.Id);
        Assert.NotNull(client.Handshake());
    }

    [Fact]
    public void AnUnknownOperationIsTypedMalformed()
    {
        using ServiceClient client = Start();
        Reply reply = client.Call("surelyNotAnOperation", null);
        Assert.NotNull(reply.Error);
        Assert.Equal("malformed", reply.Error!.Value.GetProperty("type").GetString());
        Assert.Contains("surelyNotAnOperation", reply.Error.Value.GetProperty("detail").GetString());
    }

    [Fact]
    public void MismatchIsAnsweredBeforeDecodingTheForeignFiles()
    {
        using ServiceClient client = Start();
        Reply reply = client.CallWithContract(999, "versions", null, new object[] { new { foreign = "shape" } });
        Assert.Equal("contractMismatch", reply.Error!.Value.GetProperty("type").GetString());
    }

    [Fact]
    public void AForeignServiceAnswersTypedMismatch()
    {
        using var client = new ServiceClient(Environment.GetEnvironmentVariable("XDICT_FOREIGN_SERVICE")!,
            new ServiceClientOptions { Storage = "foreign-" + Guid.NewGuid().ToString("N") });
        Reply reply = client.Call("versions", null);
        Assert.Equal("contractMismatch", reply.Error!.Value.GetProperty("type").GetString());
        Assert.Equal(Wire.Version, reply.Error.Value.GetProperty("contract").GetUInt32());
        Assert.Equal(Wire.Version + 1, reply.Error.Value.GetProperty("service").GetUInt32());
        var error = Assert.Throws<ServiceFailureException>(() => client.Handshake());
        Assert.Equal("contractMismatch", error.ErrorType);
        foreach (string language in Strings.Languages)
            Assert.False(string.IsNullOrWhiteSpace(ServiceMessages.For(error.ErrorType, language)));
    }

    [Fact]
    public void AnInterruptedCopyRefusesToStartAndTheOldPairStillWorks()
    {
        string partial = Path.Combine(Path.GetTempPath(), "xdict-partial-" + Guid.NewGuid().ToString("N") + ".exe");
        File.WriteAllBytes(partial, [0x4d, 0x5a]);
        try
        {
            var error = Assert.Throws<ServiceFailureException>(() => new ServiceClient(partial));
            Assert.Equal("closed", error.ErrorType);
            foreach (string language in Strings.Languages)
                Assert.False(string.IsNullOrWhiteSpace(ServiceMessages.For(error.ErrorType, language)));
            using ServiceClient intact = Start();
            Assert.NotNull(intact.Handshake());
        }
        finally { File.Delete(partial); }
    }

    [Fact]
    public void APathInsteadOfAHandleIsRefused()
    {
        using ServiceClient client = Start();
        Reply reply = client.Call("open", new { package = new { mdx = new { file = "C:\\Users\\joker\\Downloads\\unshared.mdx" } } });
        Assert.Equal("admission", reply.Error!.Value.GetProperty("type").GetString());
        Reply malformed = client.Call("open", new { package = new { mdx = new { path = "unshared.mdx" } } });
        Assert.Equal("malformed", malformed.Error!.Value.GetProperty("type").GetString());
    }

    private static ServiceClient Start() =>
        new(Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE names the built xdict-service executable"));
}

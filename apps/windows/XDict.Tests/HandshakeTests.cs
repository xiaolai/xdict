// The real service, started by the app's own client, answers the handshake through the pipe.
using XDict.Client;
using XDict.Contract;
using Xunit;

public class HandshakeTests
{
    [Fact]
    public void TheServiceAnswersTheHandshake()
    {
        string executable = Environment.GetEnvironmentVariable("XDICT_SERVICE")
            ?? throw new InvalidOperationException("XDICT_SERVICE names the built xdict-service executable");
        using var client = new ServiceClient(executable);
        Versions versions = client.Handshake();
        Assert.Equal(1u, versions.Protocol);
        Assert.False(string.IsNullOrWhiteSpace(versions.Core));
        Assert.True(versions.IndexFormat >= 1);
        Assert.True(versions.Normalization >= 1);
    }
}

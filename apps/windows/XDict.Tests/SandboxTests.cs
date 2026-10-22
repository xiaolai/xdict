using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using XDict.Client;
using Xunit;
using System.Net;
using System.Net.Sockets;

public class SandboxTests
{
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeFileHandle token);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(SafeFileHandle token, int kind, out int value, int size, out int needed);

    [Fact]
    public void ProductionServiceIsAnAppContainer()
    {
        using var client = new ServiceClient(Environment.GetEnvironmentVariable("XDICT_SERVICE")!);
        Assert.NotNull(client.Handshake());
        using var process = Process.GetProcessById(client.ProcessId);
        Assert.True(OpenProcessToken(process.SafeHandle, 8, out SafeFileHandle token));
        using (token)
        {
            Assert.True(GetTokenInformation(token, 29, out int isContainer, sizeof(int), out _));
            Assert.Equal(1, isContainer);
        }
    }

    [Fact]
    public void ContainerCannotOpenAnUnsharedPathOrConnectToAListener()
    {
        string fixture = Path.Combine(Path.GetTempPath(), "xdict-sandbox-" + Guid.NewGuid().ToString("N") + ".txt");
        File.WriteAllText(fixture, "XDict confinement probe");
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            using (File.OpenRead(fixture)) { }
            using (var control = new TcpClient()) control.Connect((IPEndPoint)listener.LocalEndpoint);
            using (listener.AcceptTcpClient()) { }
            using var client = new ServiceClient(Environment.GetEnvironmentVariable("XDICT_PROBE_SERVICE")!,
                new ServiceClientOptions { Storage = "probe-" + Guid.NewGuid().ToString("N") });
            var reply = client.Call("acceptanceProbe", new { path = fixture, address = listener.LocalEndpoint.ToString() });
            Assert.Null(reply.Error);
            var pathError = reply.Ok!.Value.GetProperty("pathError");
            Assert.True(pathError.ValueKind == System.Text.Json.JsonValueKind.Number && pathError.GetInt32() == 5,
                "confinement result: " + reply.Ok.Value.GetRawText());
            Assert.False(reply.Ok.Value.GetProperty("networkConnected").GetBoolean());
            Assert.False(listener.Pending());
        }
        finally { File.Delete(fixture); }
    }
}

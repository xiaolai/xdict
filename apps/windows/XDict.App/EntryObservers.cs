#if DEBUG
// Observe successful requests and canary bytes. Empty speculative TCP connections are recorded separately.
using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace XDict.App;

internal sealed class EntryObservers : IDisposable
{
    private readonly CancellationTokenSource stop = new();
    private readonly List<TcpListener> tcp = [];
    private readonly List<UdpClient> udp = [];
    public readonly ConcurrentQueue<string> Requests = new();
    public readonly ConcurrentQueue<string> CanaryPackets = new();
    private int connections, udpPackets;
    public int Connections => Volatile.Read(ref connections);
    public int UdpPackets => Volatile.Read(ref udpPackets);
    public string Canary { get; } = "xdict-private-" + Guid.NewGuid().ToString("N");

    public EntryObservers(IEnumerable<int> tcpPorts, IEnumerable<int> udpPorts)
    {
        try
        {
            foreach (int port in tcpPorts.Distinct())
            {
                var listener = new TcpListener(IPAddress.Loopback, port);
                listener.Start();
                tcp.Add(listener);
                _ = Accept(listener, port);
            }
            foreach (int port in udpPorts.Distinct())
            {
                var listener = new UdpClient(new IPEndPoint(IPAddress.Loopback, port));
                udp.Add(listener);
                _ = Datagram(listener, port);
            }
        }
        catch { Dispose(); throw; }
    }

    private async Task Accept(TcpListener listener, int port)
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(stop.Token);
                Interlocked.Increment(ref connections);
                _ = Read(client, port);
            }
        }
        catch (Exception e) when (e is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }
    private async Task Read(TcpClient client, int port)
    {
        using (client)
        try
        {
            byte[] buffer = new byte[8192];
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
            deadline.CancelAfter(TimeSpan.FromSeconds(2));
            int read = await client.GetStream().ReadAsync(buffer, deadline.Token);
            if (read == 0) return;
            string text = Encoding.UTF8.GetString(buffer, 0, read);
            if (text.StartsWith("GET ") || text.StartsWith("POST ") || text.StartsWith("HEAD ") ||
                text.StartsWith("OPTIONS ") || text.StartsWith("CONNECT ") || text.StartsWith("PUT "))
            {
                Requests.Enqueue(port + ":" + text.Split('\r')[0]);
                byte[] reply = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\nok");
                await client.GetStream().WriteAsync(reply, deadline.Token);
            }
            if (text.Contains(Canary, StringComparison.Ordinal)) CanaryPackets.Enqueue("tcp:" + port);
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or SocketException or ObjectDisposedException) { }
    }
    private async Task Datagram(UdpClient listener, int port)
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                var packet = await listener.ReceiveAsync(stop.Token);
                Interlocked.Increment(ref udpPackets);
                if (Encoding.UTF8.GetString(packet.Buffer).Contains(Canary, StringComparison.Ordinal)) CanaryPackets.Enqueue("udp:" + port);
            }
        }
        catch (Exception e) when (e is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }
    public async Task ProveAsync(int tcpPort, int udpPort)
    {
        using (var client = new TcpClient())
        {
            await client.ConnectAsync(IPAddress.Loopback, tcpPort);
            byte[] request = Encoding.ASCII.GetBytes("GET /" + Canary + " HTTP/1.1\r\nHost: localhost\r\n\r\n");
            await client.GetStream().WriteAsync(request);
            var response = new byte[128];
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            if (await client.GetStream().ReadAsync(response, timeout.Token) == 0) throw new IOException("HTTP observer saw no request");
        }
        using (var sender = new UdpClient())
            await sender.SendAsync(Encoding.ASCII.GetBytes(Canary), new IPEndPoint(IPAddress.Loopback, udpPort));
        for (int n = 0; n < 50 && CanaryPackets.Count < 2; n++) await Task.Delay(20);
        if (Requests.IsEmpty || CanaryPackets.Count < 2) throw new IOException("the observer positive control failed");
        while (Requests.TryDequeue(out _)) { }
        while (CanaryPackets.TryDequeue(out _)) { }
        Interlocked.Exchange(ref connections, 0);
        Interlocked.Exchange(ref udpPackets, 0);
    }
    public void Dispose()
    {
        stop.Cancel();
        foreach (var listener in tcp) listener.Stop();
        foreach (var listener in udp) listener.Dispose();
    }
}
#endif

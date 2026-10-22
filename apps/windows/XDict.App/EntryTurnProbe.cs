#if DEBUG
// A loopback-only TURN challenge canary. It observes dictionary-derived USERNAME bytes, not packet counts.
using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace XDict.App;

internal sealed class EntryTurnProbe : IDisposable
{
    private readonly UdpClient listener = new(new IPEndPoint(IPAddress.Loopback, 0));
    private readonly CancellationTokenSource stop = new();
    private readonly Task reader;
    private int packets, privatePackets;
    public int Port => ((IPEndPoint)listener.Client.LocalEndPoint!).Port;
    public int Packets => Volatile.Read(ref packets);
    public int PrivatePackets => Volatile.Read(ref privatePackets);
    public string Canary { get; } = "xdict-turn-private-" + Guid.NewGuid().ToString("N");
    public EntryTurnProbe() { reader = ReadAsync(); }
    private async Task ReadAsync()
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                var datagram = await listener.ReceiveAsync(stop.Token);
                byte[] bytes = datagram.Buffer;
                Interlocked.Increment(ref packets);
                if (Encoding.UTF8.GetString(bytes).Contains(Canary, StringComparison.Ordinal)) Interlocked.Increment(ref privatePackets);
                if (bytes.Length < 20 || BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(4, 4)) != 0x2112a442) continue;
                ushort type = BinaryPrimitives.ReadUInt16BigEndian(bytes);
                if (type != 3) continue; // TURN Allocate request
                using var attributes = new MemoryStream();
                static void Attribute(Stream stream, ushort kind, byte[] value)
                {
                    Span<byte> header = stackalloc byte[4];
                    BinaryPrimitives.WriteUInt16BigEndian(header, kind);
                    BinaryPrimitives.WriteUInt16BigEndian(header[2..], (ushort)value.Length);
                    stream.Write(header); stream.Write(value);
                    for (int i = value.Length; i % 4 != 0; i++) stream.WriteByte(0);
                }
                Attribute(attributes, 9, [0, 0, 4, 1, .. Encoding.ASCII.GetBytes("Unauthorized")]);
                Attribute(attributes, 0x14, Encoding.ASCII.GetBytes("xdict-test"));
                Attribute(attributes, 0x15, Encoding.ASCII.GetBytes("xdict-owned-nonce"));
                byte[] response = new byte[20 + attributes.Length];
                BinaryPrimitives.WriteUInt16BigEndian(response, 0x113);
                BinaryPrimitives.WriteUInt16BigEndian(response.AsSpan(2), (ushort)attributes.Length);
                bytes.AsSpan(4, 16).CopyTo(response.AsSpan(4));
                attributes.ToArray().CopyTo(response, 20);
                await listener.SendAsync(response, datagram.RemoteEndPoint, stop.Token);
            }
        }
        catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or SocketException) { }
    }
    public string Script => "(()=>{setTimeout(()=>{window.__turnProbe={started:false,error:''};try{const p=new RTCPeerConnection({iceServers:[{urls:'turn:127.0.0.1:" + Port + "?transport=udp',username:" + JsonSerializer.Serialize(Canary) + ",credential:'generated-test-password'}],iceTransportPolicy:'relay'});window.__turnConnection=p;p.createDataChannel('test');p.createOffer().then(o=>p.setLocalDescription(o)).then(()=>window.__turnProbe.started=true).catch(e=>window.__turnProbe.error=String(e));}catch(e){window.__turnProbe.error=String(e)}},200);return true})()";
    public void Dispose() { stop.Cancel(); listener.Dispose(); }
}
#endif

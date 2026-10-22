// The wire contract's C# side: the version, the limits and the records both the app and the service exchange.
// Normative text: apps/windows/contract/CONTRACT.md; fixtures: apps/windows/contract/fixtures.jsonl.
using System.Text.Json;

namespace XDict.Contract;

/// <summary>The contract's constants and the JSON options both sides use.</summary>
public static class Wire
{
    /// <summary>Raised by any change to the envelope, an operation, a record, a limit or an error.</summary>
    public const uint Version = 1;

    /// <summary>One JSON envelope's ceiling, read before it is decoded.</summary>
    public const int JsonMax = 1 << 20;

    /// <summary>One bulk payload's ceiling, in bytes.</summary>
    public const int BulkMax = 64 << 20;

    /// <summary>The core's records are camelCase; the options both sides write and read with.</summary>
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };
}

/// <summary>The core's versions (ADR-0007 d.11); the handshake's answer.</summary>
public sealed record Versions(uint Protocol, string Core, uint IndexFormat, uint Normalization);

/// <summary>A file's identity as the core compares it (ADR-0002; the same tuple `xdict-win-fileid` reads).</summary>
public sealed record FileIdentity(ulong Device, ulong Inode, ulong Size, long MtimeNs, long CtimeNs);

/// <summary>One file a request may read: its id, the core's name for it, the handle duplicated into the service, and
/// the app's observation of its path (null identity when nothing is at the path).</summary>
public sealed record FileObservation(string Id, string Name, ulong Handle, FileIdentity? Identity, ulong ObservedAt);

/// <summary>A reply: exactly one of <paramref name="Ok"/> and <paramref name="Error"/> is set; a bulk reply's bytes
/// travel in <paramref name="Payload"/>.</summary>
public sealed record Reply(uint Contract, ulong Id, JsonElement? Ok, JsonElement? Error, byte[]? Payload = null);

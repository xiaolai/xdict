// The wire contract's validators: what a request and a reply must be before the client or a test trusts them. The
// record shapes are the core's serde shapes (CONTRACT.md §3); this checks the envelope and the typed errors.
using System.Text.Json;

namespace XDict.Contract;

public sealed class ContractViolationException(string message) : Exception(message);

public static class Validate
{
    public static readonly string[] CoreErrorTypes =
    [
        "unsupported", "malformed", "tooLarge", "notFound", "io", "staleHandle", "editionMismatch", "sourceChanged",
        "cancelled", "incompatible", "internal",
    ];

    public static readonly string[] WireErrorTypes =
        ["contractMismatch", "admission", "busy", "deadline", "closed", "envelopeTooLarge"];

    public static void Request(JsonElement request)
    {
        Object(request, "request");
        UInt32(request, "contract");
        UInt64(request, "id");
        Text(request, "op");
        if (!request.TryGetProperty("files", out JsonElement files) || files.ValueKind != JsonValueKind.Array)
            throw new ContractViolationException("the request has no files array");
        foreach (JsonElement file in files.EnumerateArray()) FileRecord(file);
        if (!request.TryGetProperty("operation", out JsonElement operation))
            throw new ContractViolationException("the request has no operation");
        // Only `versions` and `exportData` answer with no body; every other operation carries an object, and a field
        // of another shape would reach a decoder that cannot name what it got.
        if (operation.ValueKind is not (JsonValueKind.Object or JsonValueKind.Null))
            throw new ContractViolationException("the request's operation is neither an object nor null");
    }

    /// <summary>One entry of `files` (CONTRACT.md §2): the handle the service may read, the identity the app observed
    /// and the observation's number. A record of another shape is a harness error, never a refused request.</summary>
    private static void FileRecord(JsonElement file)
    {
        Object(file, "file record");
        Text(file, "id");
        Text(file, "name");
        UInt64(file, "handle");
        UInt64(file, "observedAt");
        if (!file.TryGetProperty("identity", out JsonElement identity))
            throw new ContractViolationException("a file record has no identity");
        if (identity.ValueKind == JsonValueKind.Object)
        {
            UInt64(identity, "device");
            UInt64(identity, "inode");
            UInt64(identity, "size");
            Int64(identity, "mtimeNs");
            Int64(identity, "ctimeNs");
        }
        else if (identity.ValueKind != JsonValueKind.Null)
            throw new ContractViolationException("a file record's identity is neither an object nor null");
        if (file.TryGetProperty("write", out JsonElement write) &&
            write.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            throw new ContractViolationException("write is not a boolean");
    }

    public static void Reply(JsonElement reply)
    {
        Object(reply, "reply");
        UInt32(reply, "contract");
        UInt64(reply, "id");
        bool ok = reply.TryGetProperty("ok", out _);
        bool error = reply.TryGetProperty("error", out JsonElement detail);
        if (ok == error)
            throw new ContractViolationException("a reply carries exactly one of ok and error");
        if (!error) return;
        Object(detail, "error");
        string kind = Text(detail, "type");
        if (!CoreErrorTypes.Contains(kind, StringComparer.Ordinal) && !WireErrorTypes.Contains(kind, StringComparer.Ordinal))
            throw new ContractViolationException($"unknown error type {kind}");
        // CONTRACT.md §4's typed payloads. The shell's sentence depends on them, and the client reads them without
        // checking again: an error missing its payload is a protocol violation, never a sentence-less refusal.
        switch (kind)
        {
            case "unsupported":
                if (!detail.TryGetProperty("feature", out JsonElement feature))
                    throw new ContractViolationException("unsupported has no feature");
                Object(feature, "feature");
                break;
            case "tooLarge": Text(detail, "limit"); break;
            case "notFound": Text(detail, "what"); break;
            case "io": Text(detail, "kind"); break;
            case "incompatible": UInt32(detail, "core"); UInt32(detail, "client"); break;
            case "contractMismatch": UInt32(detail, "contract"); UInt32(detail, "service"); break;
            case "envelopeTooLarge": UInt64(detail, "bytes"); UInt64(detail, "ceiling"); break;
        }
    }

    private static void Object(JsonElement value, string what)
    {
        if (value.ValueKind != JsonValueKind.Object)
            throw new ContractViolationException($"the {what} is not an object");
    }

    private static void UInt32(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out JsonElement field) || !field.TryGetUInt32(out _))
            throw new ContractViolationException($"{name} is not an unsigned 32-bit number");
    }

    private static void UInt64(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out JsonElement field) || !field.TryGetUInt64(out _))
            throw new ContractViolationException($"{name} is not an unsigned 64-bit number");
    }

    private static void Int64(JsonElement value, string name)
    {
        // TryGetInt64 is a kind check like its unsigned sibling: a string, a null or a float answers false rather
        // than throwing, so every malformed field leaves here as the same typed refusal.
        if (!value.TryGetProperty(name, out JsonElement field) || !field.TryGetInt64(out _))
            throw new ContractViolationException($"{name} is not a 64-bit number");
    }

    private static string Text(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out JsonElement field) || field.ValueKind != JsonValueKind.String)
            throw new ContractViolationException($"{name} is not a string");
        return field.GetString()!;
    }
}

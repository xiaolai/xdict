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

    public static readonly string[] WireErrorTypes = ["contractMismatch", "admission", "busy", "deadline", "closed"];

    public static void Request(JsonElement request)
    {
        Object(request, "request");
        UInt32(request, "contract");
        UInt64(request, "id");
        Text(request, "op");
        if (!request.TryGetProperty("files", out JsonElement files) || files.ValueKind != JsonValueKind.Array)
            throw new ContractViolationException("the request has no files array");
        if (!request.TryGetProperty("operation", out _))
            throw new ContractViolationException("the request has no operation");
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

    private static string Text(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out JsonElement field) || field.ValueKind != JsonValueKind.String)
            throw new ContractViolationException($"{name} is not a string");
        return field.GetString()!;
    }
}

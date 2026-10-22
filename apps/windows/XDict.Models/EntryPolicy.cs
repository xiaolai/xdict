// Windows entry boundary. Native delegates and model tests use this same policy.
using System.Text;
using System.Text.Json;

namespace XDict.Models;

public enum EntryRoute { Refused, Document, Resource, Sound, Blocked, Font }
public sealed record EntryBridgeMessage(string Kind, string Value);

public static class EntryPolicy
{
    public const string Base = "xdict://d/";
    public static EntryRoute Route(string url, string method = "GET")
    {
        if (method != "GET" || !Uri.TryCreate(url, UriKind.Absolute, out Uri? uri) ||
            uri.Scheme != "xdict" || uri.Host != "d" || uri.UserInfo.Length != 0 || uri.Port != -1) return EntryRoute.Refused;
        string path = uri.AbsolutePath;
        int slash = path.IndexOf('/', 1);
        if (slash < 0 || slash == path.Length - 1) return EntryRoute.Refused;
        return path[1..slash] switch
        {
            "entry" => EntryRoute.Document,
            "r" => EntryRoute.Resource,
            "sound" => EntryRoute.Sound,
            "blocked" => EntryRoute.Blocked,
            "font" => EntryRoute.Font,
            _ => EntryRoute.Refused,
        };
    }

    public static bool Navigation(string url, string document, bool mainFrame)
    {
        if (!mainFrame) return url is "about:blank" or "about:srcdoc";
        return Route(url) == EntryRoute.Document && url.Split('#')[0] == document.Split('#')[0];
    }

    public static EntryBridgeMessage? Message(string json, string source, string document, string nonce, ulong generation)
    {
        if (Encoding.UTF8.GetByteCount(json) > 4096 || source.Split('#')[0] != document.Split('#')[0]) return null;
        try
        {
            using var parsed = JsonDocument.Parse(json);
            JsonElement root = parsed.RootElement;
            if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != 4 ||
                !root.TryGetProperty("nonce", out var n) || n.ValueKind != JsonValueKind.String || n.GetString() != nonce ||
                !root.TryGetProperty("generation", out var g) || !g.TryGetUInt64(out ulong valueGeneration) || valueGeneration != generation ||
                !root.TryGetProperty("kind", out var k) || k.ValueKind != JsonValueKind.String ||
                !root.TryGetProperty("value", out var v) || v.ValueKind != JsonValueKind.String) return null;
            string kind = k.GetString()!, value = v.GetString()!;
            if (value.Length == 0 || Encoding.UTF8.GetByteCount(value) > 2048) return null;
            return kind switch
            {
                "word" when value.Length <= 256 => new(kind, value),
                "link" or "sound" when Route(value) is not EntryRoute.Refused => new(kind, value),
                _ => null,
            };
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException) { return null; }
    }
}

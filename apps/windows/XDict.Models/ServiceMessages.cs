using System.Text.Json;

namespace XDict.Models;

public static class ServiceMessages
{
    /// <summary>The sentence for a typed error: a refusal names what it refused, when the core typed it.</summary>
    public static string For(JsonElement error, string? language = null)
    {
        string chosen = language ?? Strings.Language;
        string type = error.TryGetProperty("type", out JsonElement kind) ? kind.GetString() ?? "" : "";
        if (type == "unsupported" && error.TryGetProperty("feature", out JsonElement feature) &&
            feature.TryGetProperty("type", out JsonElement which))
        {
            return which.GetString() switch
            {
                "resourceLibraryV3" => Strings.Get("error.unsupported.v3", chosen),
                "registrationCode" => Strings.Get("error.unsupported.regcode", chosen),
                _ => Strings.Get("error.unsupported", chosen),
            };
        }
        if (type == "malformed") return Strings.Get("error.malformed", chosen);
        return For(type, chosen);
    }

    public static string For(string type, string? language = null) => Strings.Get(type switch
    {
        "contractMismatch" or "incompatible" => "service.incompatible",
        "closed" => "service.installation",
        "deadline" => "service.deadline",
        "staleHandle" => "service.restarted",
        _ => "app.serviceFailed",
    }, language ?? Strings.Language);
}

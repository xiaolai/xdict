// The shipped default instruction templates, embedded from conformance/ai/defaults: the normative text, one per
// language and mode. The reader may edit one; the composed question's preview and bytes are still the contract's.
using System.Reflection;

namespace XDict.AI;

public static class AITemplates
{
    public static readonly IReadOnlyList<string> Languages = ["en", "zh-Hans"];

    public static string? Default(string language, AIMode mode)
    {
        string name = $"XDict.AI.defaults.{language}.{mode.Wire()}.txt";
        using Stream? stream = typeof(AITemplates).Assembly.GetManifestResourceStream(name);
        if (stream is null) return null;
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    /// <summary>The reader's language when this version ships it; English otherwise; empty only for a broken build.</summary>
    public static string For(string language, AIMode mode) =>
        Default(language, mode) ?? Default("en", mode) ?? "";

    /// <summary>The embedded names, for a guard test that every language and mode is present.</summary>
    public static IReadOnlyList<string> EmbeddedNames() =>
        typeof(AITemplates).Assembly.GetManifestResourceNames()
            .Where(name => name.StartsWith("XDict.AI.defaults.", StringComparison.Ordinal))
            .ToArray();
}

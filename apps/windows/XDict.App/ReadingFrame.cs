using System.Reflection;
using System.Text.Json;
using XDict.Models;

namespace XDict.App;

internal static class ReadingFrame
{
    internal static byte[] Font(string name)
    {
        if (name is not ("Charis-Regular.ttf" or "Charis-Bold.ttf" or "Charis-Italic.ttf" or "Charis-BoldItalic.ttf")) return [];
        using Stream? stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("XDict.Fonts." + name);
        if (stream is null) throw new InvalidOperationException("missing font resource: " + name);
        using var output = new MemoryStream(); stream.CopyTo(output); return output.ToArray();
    }
    private static string Read(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("XDict.Reading." + name)
            ?? throw new InvalidOperationException("missing reading resource: " + name);
        using var reader = new StreamReader(stream); return reader.ReadToEnd();
    }
    private static string Css(string name) => Read(name)
        .Replace("{{fill-bp-wide}}", "560px").Replace("{{fill-bp-narrow}}", "559px")
        .Replace("{{glyph-arrow}}", "content:'\\2192'!important;display:inline-block!important")
        .Replace("{{glyph-chevron}}", "content:'\\203a'!important;display:inline-block!important")
        .Replace("{{speaker-mask}}", "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M2 6h3l4-4v12l-4-4H2zM11 4q5 4 0 8v-2q3-2 0-4z'/%3E%3C/svg%3E\")")
        .Replace("{{uk-tag}}", "'UK'").Replace("{{us-tag}}", "'US'");

    /// <summary>
    /// A replacement of shared macOS script text is checked, not assumed: when the shared file changes, an
    /// unchecked Replace silently leaves the macOS modifier or postMessage call in place on Windows.
    /// </summary>
    private static string ReplaceExact(string text, string old, string replacement, string what)
    {
        if (!text.Contains(old, StringComparison.Ordinal))
            throw new InvalidOperationException("the shared reading script no longer holds " + what);
        return text.Replace(old, replacement);
    }

    // The native bridge captures send/nonce/generation in its closure; page code gets no callable host object.
    public static string WordBridge()
    {
        string core = ReplaceExact(Read("word-clicks-core.js"), "e.metaKey === true", "e.ctrlKey === true", "the macOS word modifier");
        core = ReplaceExact(core, "!e.ctrlKey", "!e.metaKey", "the macOS modifier's other arm");
        string words = ReplaceExact(Read("word-clicks.js"),
            "webkit.messageHandlers.xdictEntry.postMessage({ kind: 'word', word: word });",
            "send({nonce,generation,kind:'word',value:word});", "the word postMessage");
        string placeholders = ReplaceExact(Read("placeholder-clicks.js"),
            "webkit.messageHandlers.xdictEntry.postMessage({ kind: 'blocked-image', url: src });",
            "send({nonce,generation,kind:'link',value:src});", "the blocked-image postMessage");
        return core + words + placeholders;
    }

    public static string DisplayScript(EntryDisplayOptions catalogue, IReadOnlyDictionary<string, string>? chosen) =>
        Read("display-options.js").Replace("{{given}}", JsonSerializer.Serialize(new { values = catalogue.Resolve(chosen), css = catalogue.Css }));

    public static string Script(ReadingPreferences preferences)
    {
        preferences = preferences.Validated();
        string tokens = Read("windows.css") + ":root{--xdict-base:" + (17 * preferences.Zoom).ToString(System.Globalization.CultureInfo.InvariantCulture) + "px}";
        string frame = ReplaceExact(Read("frame.js"), "/^-apple-system/", "/^['\"]?Segoe UI/", "the macOS system font probe");
        frame = ReplaceExact(frame, "/^-apple-system|^ui-serif/", "/^['\"]?Segoe UI|^['\"]?Microsoft YaHei UI/",
            "the macOS serif font probe");
        var substitutions = new Dictionary<string, string>
        {
            ["theme"] = preferences.Theme, ["face"] = "windows", ["hue"] = "blue", ["density"] = "main",
            ["sheet-tokens"] = JsonSerializer.Serialize(tokens),
            ["sheet-column"] = JsonSerializer.Serialize(preferences.OriginalStyle ? "html{padding:var(--xdict-pad-block) var(--xdict-pad-inline)!important}body{contain:layout;overflow-wrap:break-word}" : Css("column.css")),
            ["sheet-type"] = JsonSerializer.Serialize(preferences.OriginalStyle ? Css("original-phon.css") : Css("type.css") + Css("controls.css") + Css("marks.css") + Css("reading-labels.css")),
            ["sheet-minimal"] = "\"\"", ["names"] = JsonSerializer.Serialize(new { uk = Strings.Get("entry.pronunciation.uk"), us = Strings.Get("entry.pronunciation.us"), other = Strings.Get("entry.pronunciation") }),
            ["token-names"] = "'text','text-2','link','accent'", ["space-cap"] = preferences.OriginalStyle ? "0" : "0.25",
            ["label"] = "[data-xdict-role=label]", ["pictures"] = JsonSerializer.Serialize(Strings.Get("entry.pictures")),
        };
        foreach (var (key, value) in substitutions) frame = frame.Replace("{{" + key + "}}", value);
        if (frame.Contains("{{", StringComparison.Ordinal)) throw new InvalidOperationException("unfilled Windows reading parameter");
        string scripts = Read("frame-core.js") + Read("readability-core.js") + frame + Read("find-core.js") + Read("find.js") +
            Read("disclosure-core.js") + Read("disclosure.js") + Read("pron-run-core.js") + Read("pron-run.js");
        return "(()=>{function install(){" + scripts + "}if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',install,{once:true});else install();})();";
    }
}

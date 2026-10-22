// The capture contract's value (conformance/capture/CONTRACT.md §2-§4): one CapturedTerm, accepted or refused by the
// normative rules in their order. The term is never cleaned; only an accepted sentence is cleaned, and its range moves.
using System.Text;
using System.Text.Json.Nodes;

namespace XDict.Models;

public static class CaptureValue
{
    public const int ContextCeiling = 1000;

    /// <summary>A valid value (the transformed node) or the rule's code.</summary>
    public sealed record Result(bool Valid, string? Code, JsonNode? Value)
    {
        /// <summary>Metadata only: a value's node holds the sentence, and a log line must not.</summary>
        public override string ToString() => Valid ? "capture value (valid)" : $"capture value ({Code})";
    }

    public static Result Make(JsonNode input)
    {
        // A value is a JSON object. Anything else cannot carry the contract's fields, and indexing a non-object
        // throws; it is refused like an empty term instead.
        if (input is not JsonObject root) return Invalid("term");
        // 1. The term: not empty, no Unicode control character (Cc).
        if (root["term"] is not JsonValue termNode || !termNode.TryGetValue(out string? term) || string.IsNullOrEmpty(term))
            return Invalid("term");
        if (term.Any(char.IsControl)) return Invalid("term");

        // 2. Confidence: finite, within 0..1.
        if (!TryFinite(root["confidence"], out double confidence) || confidence < 0 || confidence > 1)
            return Invalid("confidence");

        // 3. Every coordinate is finite.
        JsonNode? box = root["box"];
        string? boxKind = Text(Map(box, "kind"));
        if (boxKind == "measured")
        {
            JsonNode? rect = Map(box, "rect");
            if (!TryFinite(Map(rect, "x"), out _) || !TryFinite(Map(rect, "y"), out _) ||
                !TryFinite(Map(rect, "width"), out _) || !TryFinite(Map(rect, "height"), out _)) return Invalid("geometry");
        }
        else if (boxKind == "clickPlacement")
        {
            JsonNode? point = Map(box, "point");
            if (!TryFinite(Map(point, "x"), out _) || !TryFinite(Map(point, "y"), out _)) return Invalid("geometry");
        }
        if (root["pointer"] is JsonObject pointer)
        {
            foreach (string axis in new[] { "x", "y" })
                if (pointer[axis] is not null && !TryFinite(pointer[axis], out _)) return Invalid("geometry");
        }

        // 4-6. An available context: ceiling, range, canonical equality, then cleaning with the range moving.
        JsonNode value = input.DeepClone();
        if (Map(value, "context") is not JsonObject context || Text(context["kind"]) != "available")
            return new Result(true, null, value);
        string sentence = Text(context["sentence"]) ?? "";
        if (context["term"] is not JsonObject range) return Invalid("range");
        bool startAsString = range["start"] is JsonValue startScalar && startScalar.TryGetValue(out string? _);
        if (!TryIndex(range["start"], out int start) || !TryIndex(range["length"], out int length)) return Invalid("range");
        if (CheckContext(sentence, start, length, term) is { } refusal) return Invalid(refusal);

        (string cleaned, int movedStart) = Clean(sentence, start);
        context["sentence"] = cleaned;
        // The range keeps the encoding it arrived in: the vectors carry it as a string, and a node's kind never changes.
        range["start"] = startAsString ? JsonValue.Create(movedStart.ToString()) : JsonValue.Create(movedStart);
        return new Result(true, null, value);
    }

    /// <summary>A map member, or null when the node is not a map: a hostile value never throws out of a lookup.</summary>
    private static JsonNode? Map(JsonNode? node, string key) => node is JsonObject map ? map[key] : null;

    private static Result Invalid(string code) => new(false, code, null);

    /// <summary>Rules 4-5 alone, for a context that arrives later than its term (a settlement): the code, or null.</summary>
    public static string? CheckContext(string sentence, int start, int length, string term)
    {
        if (sentence.Length > ContextCeiling) return "context.too-long";
        if (start < 0 || length <= 0 || start + length > sentence.Length) return "range";
        if (SplitsSurrogate(sentence, start, length)) return "range.splits-character";
        if (length != term.Length ||
            !string.Equals(sentence.Substring(start, length).Normalize(NormalizationForm.FormC), term.Normalize(NormalizationForm.FormC),
                StringComparison.Ordinal)) return "range";
        return null;
    }

    /// <summary>A string a hostile input may not carry: anything but a JSON string reads as absent, never throws.</summary>
    private static string? Text(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue(out string? text) ? text : null;

    private static bool TryFinite(JsonNode? node, out double value)
    {
        value = 0;
        if (node is not JsonValue scalar) return false;
        if (scalar.TryGetValue(out double number)) { value = number; return double.IsFinite(number); }
        // A value built in code rather than parsed is backed by its own CLR type; its JSON text is the common reading.
        try
        {
            if (double.TryParse(scalar.ToJsonString(), System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture, out number))
            {
                value = number;
                return double.IsFinite(number);
            }
        }
        catch (Exception) { }
        return false;
    }

    /// <summary>A range index: a JSON number, or a string holding one (the capture vectors' encoding).</summary>
    private static bool TryIndex(JsonNode? node, out int value)
    {
        value = 0;
        if (node is not JsonValue scalar) return false;
        if (scalar.TryGetValue(out value)) return true;
        if (scalar.TryGetValue(out string? text))
            return int.TryParse(text, System.Globalization.NumberStyles.Integer,
                System.Globalization.CultureInfo.InvariantCulture, out value);
        try
        {
            return int.TryParse(scalar.ToJsonString(), System.Globalization.NumberStyles.Integer,
                System.Globalization.CultureInfo.InvariantCulture, out value);
        }
        catch (Exception) { return false; }
    }

    private static bool SplitsSurrogate(string sentence, int start, int length) =>
        SentenceCut.SplitsSurrogate(sentence, start, length);

    /// <summary>Rule 6: tab, LF, CR, VT, FF and NEL become a space; other controls vanish; the start moves.</summary>
    private static (string Cleaned, int MovedStart) Clean(string sentence, int start)
    {
        var text = new StringBuilder(sentence.Length);
        int moved = start;
        for (int i = 0; i < sentence.Length; i++)
        {
            char c = sentence[i];
            if (i == start) moved = text.Length;
            if (c is '\t' or '\n' or '\r' or '\v' or '\f' or '\u0085') text.Append(' ');
            else if (char.IsControl(c)) { }
            else text.Append(c);
        }
        return (text.ToString(), moved);
    }
}

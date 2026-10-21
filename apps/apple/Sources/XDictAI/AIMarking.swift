/// **The measured prompt marks the target word in its sentence** (`conformance/ai/CONTRACT.md` §3; ADR-0021 d.2: NSS
/// 牛津 58.1 → 64.0, p = 0.002). The marking is the composer's, never the model's.
public enum AIMarking {
    /// U+00AB, around the word, as the measurement used.
    static let open: Character = "«"
    /// U+00BB.
    static let close: Character = "»"

    /// `sentence` with the word at `range` between `«` and `»`, in UTF-16 units; the sentence unchanged where the range
    /// is absent, outside the sentence, empty, or splits a surrogate pair.
    public static func marked(sentence: String, range: AITermRange) -> String {
        guard case .range(let start, let length) = range, length > 0 else { return sentence }
        let units = Array(sentence.utf16)
        guard start >= 0, length > 0, start <= units.count, length <= units.count - start else { return sentence }
        let end = start + length
        // A boundary inside a surrogate pair has no whole character, so nothing is marked.
        if start < units.count, UTF16.isTrailSurrogate(units[start]) { return sentence }
        if end < units.count, UTF16.isTrailSurrogate(units[end]) { return sentence }
        let before = String(decoding: units[0..<start], as: UTF16.self)
        let word = String(decoding: units[start..<end], as: UTF16.self)
        let after = String(decoding: units[end...], as: UTF16.self)
        return before + String(open) + word + String(close) + after
    }
}

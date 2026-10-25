/// **The measured prompt marks the target word in its sentence** (`conformance/ai/CONTRACT.md` §3; ADR-0021 d.2: NSS
/// 牛津 58.1 → 64.0, p = 0.002). The marking is the composer's, never the model's.
public enum AIMarking {
    /// U+00AB, around the word, as the measurement used.
    static let open: Character = "«"
    /// U+00BB.
    static let close: Character = "»"

    /// **Where a range marks, or nil when `marked` would return the sentence unchanged**: the range is absent, not
    /// positive, outside the sentence, or starts or ends inside a surrogate pair. This decides without building the
    /// UTF-16 array, so a caller can size a rendering before copying anything (audit round 2, 2026-10-25).
    private static func marks(_ sentence: String, _ range: AITermRange) -> (start: Int, end: Int)? {
        guard case .range(let start, let length) = range, length > 0, start >= 0 else { return nil }
        let units = sentence.utf16
        guard start <= units.count, length <= units.count - start else { return nil }
        let end = start + length
        if start < units.count,
           UTF16.isTrailSurrogate(units[units.index(units.startIndex, offsetBy: start)]) { return nil }
        if end < units.count,
           UTF16.isTrailSurrogate(units[units.index(units.startIndex, offsetBy: end)]) { return nil }
        return (start, end)
    }

    /// `sentence` with the word at `range` between `«` and `»`, in UTF-16 units; the sentence unchanged where the range
    /// is absent, outside the sentence, empty, or splits a surrogate pair.
    public static func marked(sentence: String, range: AITermRange) -> String {
        guard let (start, end) = marks(sentence, range) else { return sentence }
        let units = Array(sentence.utf16)
        let before = String(decoding: units[0..<start], as: UTF16.self)
        let word = String(decoding: units[start..<end], as: UTF16.self)
        let after = String(decoding: units[end...], as: UTF16.self)
        return before + String(open) + word + String(close) + after
    }

    /// **The UTF-8 bytes `marked` adds at this range**: the two markers when it marks, nothing when it does not.
    public static func markingBytes(sentence: String, range: AITermRange) -> Int {
        marks(sentence, range) == nil ? 0 : String(open).utf8.count + String(close).utf8.count
    }
}

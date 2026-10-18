import Foundation

/// **The script a captured word is written in** — the hover filter's question (XiaolaiDict ADR-0015: scripts, never
/// languages; one word gives a language recogniser too little to tell English from German). Capture's own, not a
/// dictionary's: ported from XiaolaiDict's `ProbeScript.dominant(in:)` and `letterScript(of:)` alone.
public enum CaptureScript: String, Codable, Sendable, CaseIterable, Comparable {
    case latin
    case han
    case hangul
    case kana

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The script `text` is mostly written in, or nil where it is written in none.
    ///
    /// **Never the first scalar.** Text the reader rested on is whatever was on their screen: it opens
    /// with a quotation mark, carries a digit, or mixes scripts where OCR took in a neighbour. A
    /// first-scalar classifier answered nil for `"hold"` in quotation marks and han for `the 水`
    /// (XiaolaiDict ADR-0015).
    ///
    /// Letters vote and nothing else does. Punctuation, digits and spaces are skipped rather than
    /// counted, so a string with no letters at all answers nil — a number is not written in a
    /// script, and naming one for it would put every `42` in the reader's history under Latin.
    ///
    /// **Kana absorbs han rather than merely outvoting it.** 水 alone is Chinese and 水 beside する is
    /// Japanese. So any
    /// kana makes the han beside it Japanese too — otherwise `勉強する` is 2 han against 2 kana and
    /// comes out a tie, and `漢字を勉強する` comes out Chinese on a majority of kanji.
    ///
    /// **Compatibility-normalised first** (NFKC), which does two jobs. It settles composed against
    /// decomposed — `ế` as one scalar and as `e` plus two combining marks answered nil and Latin
    /// respectively, and a screen capture can be either. And it folds the presentation forms —
    /// ligatures, halfwidth kana, fullwidth Latin, squared words — into the letters they stand for,
    /// which is what stops the block list below growing every time a new corner of Unicode turns
    /// up. Two rounds of this classifier were spent adding blocks one at a time; `ﬀ` and `ｶ` are
    /// not new scripts, they are `ff` and `カ` in costume. The text is normalised for the reading
    /// only — nothing normalised is stored or shown.
    ///
    /// A tie among the rest goes to whichever appeared first, so the answer does not depend on the
    /// order a dictionary happens to enumerate.
    public static func dominant(in text: String) -> CaptureScript? {
        var counts: [CaptureScript: Int] = [:]
        var order: [CaptureScript] = []
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
            guard let script = letterScript(of: scalar) else { continue }
            if counts[script] == nil { order.append(script) }
            counts[script, default: 0] += 1
        }
        if let kana = counts[.kana], let han = counts.removeValue(forKey: .han) {
            counts[.kana] = kana + han
            order.removeAll { $0 == .han }
        }
        guard let best = counts.values.max() else { return nil }
        return order.first { counts[$0] == best }
    }

    /// The script one scalar is a letter of. Nil for punctuation, digits, spaces and symbols.
    ///
    /// **Letterhood is asked of Unicode, never inferred from the block.** A block holds a script's
    /// punctuation too: `U+30FB ・` is a separator sitting inside Katakana, and counting it as kana
    /// made `水・` Japanese — which, through the han-absorption rule, refused a Chinese word for a
    /// reader who studies Chinese. `isAlphabetic` is what separates the letters from the furniture,
    /// and it keeps `U+30FC ー`, a modifier letter, where it belongs: ラーメン is one word.
    ///
    /// **The blocks are listed in full rather than approximately.** Text a scalar classifier cannot
    /// name is looked up — unknown is permissive on purpose — so every block left out is a hole in
    /// the reader's filter rather than a missing nicety. The first pass covered ASCII, one Latin
    /// range, the basic CJK planes and the main kana blocks, and let halfwidth katakana `ｶﾀｶﾅ`,
    /// supplementary han `𠮷` and `ế` through a filter set to exclude them.
    static func letterScript(of scalar: Unicode.Scalar) -> CaptureScript? {
        guard scalar.properties.isAlphabetic else { return nil }
        switch scalar.value {
        // Hiragana, Katakana, their phonetic extensions, and the supplements past the basic
        // plane. The halfwidth forms are not listed: NFKC has already folded them to fullwidth.
        case 0x3040...0x30FF, 0x31F0...0x31FF,
             0x1B000...0x1B0FF, 0x1B100...0x1B12F, 0x1B130...0x1B16F:
            return .kana
        // Jamo, compatibility jamo, the syllable block, both jamo extensions, halfwidth jamo.
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
             0xAC00...0xD7AF, 0xFFA0...0xFFDC:
            return .hangul
        // CJK unified ideographs, extensions A through H, and both compatibility blocks. The
        // extensions past B live in the supplementary planes, which a `UInt32` range reaches and
        // a `UInt16`-shaped assumption does not.
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2A6DF, 0x2A700...0x2EBEF, 0x2F800...0x2FA1F,
             0x30000...0x323AF:
            return .han
        // **Greek, sitting inside Latin Extended-E.** `U+AB65` is GREEK LETTER SMALL CAPITAL
        // OMEGA and it does not decompose, so nothing upstream removes it: covering the block
        // whole swept Greek into Latin and would have looked it up for a Latin-only reader. The
        // same lesson as `・` in the Katakana block — a block is a range of code points, never a
        // claim about script — and the reason each range below is bounded rather than rounded off.
        case 0xAB65:
            return nil
        // Basic Latin, Latin-1 Supplement, Extended-A and -B, IPA, Extended Additional,
        // Extended-C, -D and -E. The fullwidth forms and the ligatures are not listed: NFKC has
        // already folded them to plain letters.
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x0250...0x02AF,
             0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F:
            return .latin
        default:
            return nil
        }
    }
}

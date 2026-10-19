import Foundation

/// **Acquisition resource limits** — how much capture may read, belonging to capture (ADR-0014 decision 3).
///
/// Each is applied **before** segmentation, scanning or formatting, so nothing past it is ever assembled, and each names
/// its unit. They are budgets, not design values: integers, never tokens (decision 11).
///
/// **There is no key limit here, on purpose.** How long a term may be is the consumer's admission rule (XDict's search
/// admits 200 characters, phrases kept), and capture never truncates a term to fit one: a term longer than the consumer
/// admits arrives whole and is refused there, with its reason.
public struct CaptureLimits: Sendable, Equatable {
    /// The most text read from a document around a selection, in **UTF-16 units**, per side — a window, not the whole
    /// document (a long document is megabytes over IPC for one sentence).
    public let readRadiusUTF16: Int
    /// The most context joined around the term, in **UTF-16 units** (XiaolaiDict's sentence bound, 1000).
    public let contextUTF16: Int
    /// The most recognised observations taken from one capture, in **observations**.
    public let observations: Int
    /// The widest tile the recogniser reads, in **pixels** (XiaolaiDict ADR-0016 addendum: 2000 px reads small text
    /// exactly where a 5120 px band read 47%).
    public let tilePixels: Int
    /// How far neighbouring tiles overlap, in **pixels**.
    public let tileOverlapPixels: Int

    /// Nil where a limit cannot be applied: not positive, a context over the ceiling, or a tile no wider than its overlap
    /// (which cannot tile).
    public init?(readRadiusUTF16: Int, contextUTF16: Int, observations: Int, tilePixels: Int, tileOverlapPixels: Int) {
        guard readRadiusUTF16 > 0, contextUTF16 > 0, contextUTF16 <= Self.contextCeilingUTF16, observations > 0,
              tileOverlapPixels > 0,
              tilePixels > tileOverlapPixels
        else { return nil }
        self.readRadiusUTF16 = readRadiusUTF16
        self.contextUTF16 = contextUTF16
        self.observations = observations
        self.tilePixels = tilePixels
        self.tileOverlapPixels = tileOverlapPixels
    }

    /// The values XiaolaiDict shipped and measured: a 2000-unit read radius each side, a 1000-unit context, 2000 px
    /// tiles overlapping by 600; 512 observations bounds one strip (a 600 pt strip of 14 pt text holds about 40 rows).
    /// **The most context any limit may allow, in UTF-16 units** — XiaolaiDict's sentence bound. A limit may tighten it,
    /// never loosen it, and the captured term refuses a longer sentence (`CaptureValueError.contextTooLong`).
    public static let contextCeilingUTF16 = 1000

    public static let shipped = CaptureLimits(
        uncheckedReadRadius: 2000, context: contextCeilingUTF16, observations: 512, tile: 2000, overlap: 600)

    private init(uncheckedReadRadius: Int, context: Int, observations: Int, tile: Int, overlap: Int) {
        readRadiusUTF16 = uncheckedReadRadius
        contextUTF16 = context
        self.observations = observations
        tilePixels = tile
        tileOverlapPixels = overlap
    }

    /// `text` cut to at most `contextUTF16` units around `range`, on whole characters — never inside a surrogate pair or
    /// a combining sequence (an extended grapheme cluster, as `NSString` composes them) — what a reader
    /// hands to segmentation, never after it. The range is moved into the cut text; nil where `range` is not inside
    /// `text` or is longer than the limit itself (the term is never cut).
    public func window(of text: String, around range: NSRange) -> (text: String, range: NSRange)? {
        let units = Array(text.utf16)
        guard range.location >= 0, range.length >= 0, range.location <= units.count,
              range.length <= units.count - range.location, range.length <= contextUTF16
        else { return nil }
        guard units.count > contextUTF16 else { return (text, range) }
        let spare = contextUTF16 - range.length
        var start = max(0, range.location - spare / 2)
        var end = min(units.count, start + contextUTF16)
        start = max(0, end - contextUTF16)
        // **Whole characters only**: a start inside a composed character moves past it, an end inside one moves before
        // it — a surrogate pair, a base and its combining marks, an emoji sequence alike.
        let composed = text as NSString
        if start > 0, start < units.count {
            let character = composed.rangeOfComposedCharacterSequence(at: start)
            if character.location < start { start = NSMaxRange(character) }
        }
        if end > 0, end < units.count {
            let character = composed.rangeOfComposedCharacterSequence(at: end)
            if character.location < end { end = character.location }
        }
        guard start <= range.location, end >= range.location + range.length else { return nil }
        let cut = String(decoding: units[start..<end], as: UTF16.self)
        return (cut, NSRange(location: range.location - start, length: range.length))
    }
}

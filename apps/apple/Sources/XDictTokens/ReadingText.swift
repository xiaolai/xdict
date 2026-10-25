import AppKit

/// **The companion's reading text, in the dictionary's own type** (ADR-0021 decision 14): the entry body's face and size —
/// 16 pt serif, New York with Songti for Chinese — at the reading style's 1.4 leading. Both numbers come from the same
/// `Tokens/tokens.toml` rows as the CSS the entry view installs; `ReadingTextTests` holds the Swift side to the CSS
/// values, so a change to one without the other fails.
///
/// **What SwiftUI can and cannot promise** (Codex refutation, 2026-10-25; audit round 1, 2026-10-25): `lineSpacing` is
/// one value added to every line's natural box; it does not set a CSS line height, and it is computed from the base face
/// alone because the fallback a run will draw with is known only at layout. So the reachable rule is: the target is
/// 16 × 1.4; the extra spacing is the target minus the base font's natural height, never negative. A Latin line then
/// draws at exactly the target; a line whose fallback is taller than the base (a CJK run can be) draws its own taller
/// box plus that same spacing — never shrunk, and not held to 22.4 either. The render measures the result.
public enum ReadingText {
    /// The reading body's face and size: `text.readingBody` (P18).
    public static let body = Tokens.TextRole.readingBody

    /// The same face and size at emphasis: the matched run inside an example pair, where only the weight changes.
    public static let emphasized = Tokens.TextRole.readingBodyEmphasized

    /// The reading body's target line height in points: the drawn font's size times `reading.leading` (P18). Read from
    /// the resolved font, not the token's optional size (audit round 2, 2026-10-25): a role without a fixed size still
    /// has a real one.
    public static var lineHeight: CGFloat {
        body.nsFont.pointSize * CGFloat(Tokens.Reading.leading)
    }

    /// **The extra spacing for a target box and a font's natural box**, never negative (audit round 3, 2026-10-25): both
    /// branches are checkable without a real font taller than the target.
    public static func spacing(target: CGFloat, natural: CGFloat) -> CGFloat {
        max(0, target - natural)
    }

    /// The extra spacing that brings the base font's natural line box to the target, or zero when it is already taller.
    /// A taller fallback run keeps its own box and receives the same spacing (see the type comment).
    public static var lineSpacing: CGFloat {
        spacing(target: lineHeight, natural: naturalHeight(of: body.nsFont))
    }

    /// The natural line box of an AppKit font: ascender to descender plus its leading, as AppKit lays it out.
    static func naturalHeight(of font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }
}

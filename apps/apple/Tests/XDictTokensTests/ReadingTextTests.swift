import AppKit
import Foundation
import Testing
@testable import XDictTokens

/// **The companion's reading text is the dictionary's, held to the CSS by one comparison** (ADR-0021 d.14): the entry
/// view draws `--xdict-base: 16px` at `--xdict-leading: 1.4`; the pane draws `text.readingBody` at `reading.leading`.
/// Both are generated from `Tokens/tokens.toml`, so this test is a drift guard between the two representations — and the
/// positive control proves the guard can fail.
struct ReadingTextTests {
    /// The reading style's CSS tokens, as the entry view installs them.
    static func css(_ name: String) -> String? {
        Tokens.ReadingStyle.root.first { $0.0 == name }?.1
    }

    /// What the CSS says, parsed: "16px" → 16, "1.4" → 1.4.
    static func cssNumber(_ name: String) -> Double? {
        guard var text = css(name) else { return nil }
        if text.hasSuffix("px") { text.removeLast(2) }
        guard text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return Double(text)
    }

    /// The comparison itself, taking both sides as arguments so its control can feed it wrong values. Each problem names
    /// both values plainly, `nil` included (audit round 2, 2026-10-25: the old message printed `Optional(15.0)`).
    static func parityProblems(base: Double?, leading: Double?, pointSize: CGFloat?, swiftLeading: Double) -> [String] {
        func number(_ value: Double?) -> String { value.map { "\($0)" } ?? "nil" }
        guard let base, let pointSize, abs(Double(pointSize) - base) < 0.001 else {
            return ["the CSS base \(number(base)) is not the Swift \(number(pointSize.map { Double($0) }))"]
        }
        guard let leading, abs(leading - swiftLeading) < 0.001 else {
            return ["the CSS leading \(number(leading)) is not the Swift \(swiftLeading)"]
        }
        return []
    }

    @Test func theSwiftReadingBodyIsTheCSSBase() {
        #expect(Self.parityProblems(base: Self.cssNumber("base"), leading: Self.cssNumber("leading"),
                                    pointSize: ReadingText.body.pointSize,
                                    swiftLeading: Tokens.Reading.leading) == [],
                "the pane's reading type has drifted from the entry's CSS: run Tools/tokens.py gen and check both rows")
        #expect(ReadingText.body.pointSize == 16)
        #expect(Tokens.Reading.leading == 1.4)
    }

    /// **The guard can fail**: a wrong base and a wrong leading are each named, from the same comparison the test above
    /// runs on the real values.
    @Test func aDriftedReadingTypeIsNamed() {
        // **One case per drift, each with the diagnostic it must produce** (audit round 3, 2026-10-25).
        let cases: [(base: Double?, leading: Double?, pointSize: CGFloat?, swiftLeading: Double, expected: String)] = [
            (15, 1.4, 16, 1.4, "the CSS base 15.0 is not the Swift 16.0"),
            (16, 1.6, 16, 1.4, "the CSS leading 1.6 is not the Swift 1.4"),
            (nil, 1.4, 16, 1.4, "the CSS base nil is not the Swift 16.0"),
            (16, nil, 16, 1.4, "the CSS leading nil is not the Swift 1.4"),
        ]
        for one in cases {
            let problems = Self.parityProblems(base: one.base, leading: one.leading, pointSize: one.pointSize,
                                               swiftLeading: one.swiftLeading)
            #expect(problems == [one.expected], "\(one.expected) was not named: \(problems)")
        }
    }

    /// The body is serif at the reading size — the face the entry is drawn in, not the UI's.
    @Test func theReadingBodyIsTheSerifAtTheBodysSize() {
        #expect(ReadingText.body.spec == .fixed(size: 16, weight: .regular, design: .serif, italic: false))
    }

    /// **The target line box is 16 × 1.4**, and the extra spacing never goes negative: when the base font's own box is
    /// already taller than the target the pane adds nothing rather than shrinking it. The spacing comes from the base
    /// face; a fallback run draws its own box plus that spacing, which the render measures.
    @Test func theLineTargetIsSixteenTimesOnePointFour() {
        #expect(ReadingText.lineHeight == 22.4)
        // **The expected spacing is computed here from NSFont** (audit round 3, 2026-10-25): the production helper cannot
        // make a wrong font metric agree with itself.
        let font = ReadingText.body.nsFont
        let natural = font.ascender - font.descender + font.leading
        #expect(natural > 0)
        #expect(ReadingText.lineSpacing == max(0, 22.4 - natural))
    }

    /// **Both branches of the spacing rule**, without needing a real font taller than the target (audit round 3).
    @Test func theSpacingIsTheTargetMinusTheNaturalBoxAndNeverNegative() {
        // The subtraction is in points, so the positive branch is compared with a tolerance (22.4 − 18 is not exactly
        // 4.4 in binary floating point); the clamped branches are exact zeros.
        #expect(abs(ReadingText.spacing(target: 22.4, natural: 18) - 4.4) < 0.001)
        #expect(ReadingText.spacing(target: 22.4, natural: 22.4) == 0)
        #expect(ReadingText.spacing(target: 22.4, natural: 30) == 0)
    }
}

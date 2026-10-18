import Foundation
import Testing
@testable import XDictEntryView
import XDictTokens

/// **Before the page is drawn from the generated sheets, they are what it is drawn from today, byte for byte**
/// (phase 2 of the token system, test-first): `tokens.css` joined is `EntryReadingFrame.tokens`' `:root` block,
/// `palette.css` is `paletteCSS`, `density.css` declares what `type.css`'s R7a block declares, and the generated Swift
/// data is the arrays. Deleted with the arrays once the generated files are the only copy.
struct EntryTokensCSSTests {
    static func declarations(_ css: String) -> [String] {
        css.split(separator: "}").flatMap { block -> [String] in
            let parts = block.split(separator: "{", maxSplits: 1)
            guard parts.count == 2 else { return [] }
            let selector = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            return parts[1].split(separator: ";").map { selector + " " + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.hasSuffix(" ") }
        }
    }

    @Test func theRootSheetIsTheFramesTokens() {
        let legacy = ":root{" + EntryReadingFrame.tokens.map { "--xdict-\($0.0):\($0.1);" }.joined() + "}"
        #expect(EntryStyle.bundled.css("tokens.css") == legacy)
    }

    @Test func thePaletteSheetIsThePaletteCSS() {
        #expect(EntryStyle.bundled.css("palette.css") == EntryReadingFrame.paletteCSS)
    }

    @Test func theDensitySheetDeclaresTypeCSSsBlock() throws {
        let type = EntryStyle.bundled.css("type.css")
        let start = try #require(type.range(of: ":root{--xdict-space-translation"))
        let end = try #require(type.range(of: "--xdict-space-pos:1em}", range: start.upperBound..<type.endIndex))
        #expect(Self.declarations(String(type[start.lowerBound..<end.upperBound]))
                == Self.declarations(EntryStyle.bundled.css("density.css")))
    }

    @Test func theGeneratedDataIsTheArrays() {
        #expect(Tokens.ReadingStyle.root.map { $0.0 + ":" + $0.1 } == EntryReadingFrame.tokens.map { $0.0 + ":" + $0.1 })
        #expect(Tokens.ReadingStyle.palette.map { [$0.0, $0.1, $0.2] } == EntryReadingFrame.colours.map { [$0.0, $0.1, $0.2] })
        for (accent, generated) in [(EntryReadingFrame.Accent.teal, Tokens.ReadingStyle.accentTeal),
                                    (.red, Tokens.ReadingStyle.accentRed), (.indigo, Tokens.ReadingStyle.accentIndigo)] {
            #expect(accent.values == generated)
        }
    }
}

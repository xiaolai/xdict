import Foundation
import Testing
@testable import XDictEntryView

/// **`tokens.css` (generated from `Tokens/tokens.toml`) declares exactly the reading style's tokens** that
/// `EntryReadingFrame` puts on the page today: every `--xdict-*` on `:root`, the palette per theme and the accents per
/// hue, name for name and value for value. Phase 1 of the token system: the page is still drawn from
/// `EntryReadingFrame.tokens`, and this holds the two equal until phase 2 draws it from the file.
struct EntryTokensCSSTests {
    /// Each block of the file, by its selector, as its declarations in order.
    static func blocks() throws -> [String: [(String, String)]] {
        let css = try #require(EntryStyleFiles.text["tokens.css"], "tokens.css is not compiled in")
        var out: [String: [(String, String)]] = [:], selector: String?
        for line in css.split(separator: "\n").map(String.init) where !line.hasPrefix("/*") {
            if line.hasSuffix("{") {
                selector = String(line.dropLast())
            } else if line == "}" {
                selector = nil
            } else if let selector, let colon = line.firstIndex(of: ":"), line.hasPrefix("--xdict-"), line.hasSuffix(";") {
                out[selector, default: []].append((String(line[line.index(line.startIndex, offsetBy: 8)..<colon]),
                                                   String(line[line.index(after: colon)...].dropLast())))
            } else {
                Issue.record("tokens.css: unexpected line \(line)")
            }
        }
        return out
    }

    static func same(_ a: [(String, String)]?, _ b: [(String, String)]) -> Bool {
        guard let a else { return false }
        return a.map { $0.0 + ":" + $0.1 } == b.map { $0.0 + ":" + $0.1 }
    }

    @Test func theRootTokensAreTheFramesTokens() throws {
        #expect(Self.same(try Self.blocks()[":root"], EntryReadingFrame.tokens))
    }

    @Test func thePaletteIsTheFramesPalette() throws {
        let blocks = try Self.blocks()
        #expect(Self.same(blocks[":root[data-xdict-theme=light]"], EntryReadingFrame.colours.map { ($0.0, $0.1) }))
        #expect(Self.same(blocks[":root[data-xdict-theme=dark]"], EntryReadingFrame.colours.map { ($0.0, $0.2) }))
    }

    @Test func theAccentsAreTheFramesAccents() throws {
        let blocks = try Self.blocks()
        for accent in EntryReadingFrame.Accent.allCases {
            #expect(Self.same(blocks[":root[data-xdict-theme=light][data-xdict-hue=\(accent.rawValue)]"],
                              [("accent", accent.values.light)]))
            #expect(Self.same(blocks[":root[data-xdict-theme=dark][data-xdict-hue=\(accent.rawValue)]"],
                              [("accent", accent.values.dark)]))
        }
        // `:root`, a palette per theme, and an accent per hue and theme: nothing else.
        #expect(try Self.blocks().count == 3 + 2 * EntryReadingFrame.Accent.allCases.count)
    }
}

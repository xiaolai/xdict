import Foundation
import JavaScriptCore
import Testing
@testable import XDictEntryView

/// **The XDict reading frame** (owner, 2026-10-15): every dictionary shown with the same margins, column, type and
/// density, applied after the dictionary's CSS, with no per-dictionary code. Its pure parts run in JavaScriptCore.
struct ReadingFrameTests {
    static func core() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
        context.evaluateScript(EntryScripts.frameCore)
        return context
    }

    /// The entry's dominant size is the size most of its text is set in, by characters, not by elements: one long
    /// definition at 13px outweighs ten 20px labels.
    @Test func theDominantSizeIsTheOneMostCharactersAreSetIn() throws {
        let context = try Self.core()
        func dominant(_ samples: String) -> Double? { context.evaluateScript("XDictFrameCore.dominant(\(samples))")?.toDouble() }
        #expect(dominant("[[20, 5], [20, 5], [13, 400], [16, 30]]") == 13)
        #expect(dominant("[[12, 100], [12.2, 100], [16, 150]]") == 12)   // sizes within half a pixel count as one
        #expect(dominant("[]")?.isNaN == true)
        #expect(dominant("[[0, 100]]")?.isNaN == true)
    }

    /// The tokens are the spec's names (`reading-style.md` §1), every one, with a value per theme for the colours.
    @Test func theTokensAreTheSpecsNames() {
        let css = EntryReadingFrame.tokensCSS
        for name in ["base", "font", "font-cjk", "font-phon", "font-mono", "fs-xs", "fs-s", "fs-m", "fs-l", "fs-xl",
                     "fs-xxl", "fs-min", "fs-max", "leading", "leading-tight", "weight-bold", "space-1", "space-5", "gap",
                     "indent", "indent-max", "measure", "pad-block", "pad-inline", "cell-pad", "radius", "hit", "icon",
                     "bg", "panel", "text", "text-2", "rule", "link", "phon-colour", "plate", "mark", "mark-current",
                     "red-deep", "pink-tint"] {
            #expect(css.contains("--xdict-\(name):"), "\(name)")
        }
        #expect(css.contains("--xdict-measure:36em;"))
        #expect(css.contains(":root[data-xdict-theme=light]{--xdict-bg:#ffffff;"))
        #expect(css.contains(":root[data-xdict-theme=dark]{--xdict-bg:#1e1e1e;"))
        #expect(!css.contains("--xdict-base-size"))
    }

    /// R10 and R13: the quirks-mode table reset undone; only an unwrapped data table scrolls itself, no table is made a
    /// block otherwise; the body contains a dictionary's fixed elements.
    @Test func tablesAndContainmentFollowTheSpec() {
        let css = EntryReadingFrame.columnCSS
        #expect(css.contains("table{font:inherit;line-height:inherit;color:inherit;white-space:inherit;text-align:inherit;"))
        #expect(css.contains("[data-xdict-scroll]{overflow-x:auto;max-width:100%"))
        #expect(!css.contains("body table{display:block"))
        #expect(css.contains(":not([data-xdict-scroll])>table[data-xdict-table=data]{display:block"))
        #expect(css.contains("contain:layout !important"))
        #expect(css.contains(":where(a:any-link){color:var(--xdict-link)}"))
    }

    /// The frame is layers, each switchable on its own; off is the dictionary as it styles itself, plus the inset.
    @Test func eachLayerIsSwitchableAndOffAddsNothing() {
        let off = EntryScripts.appearance(.light, frame: [])
        let on = EntryScripts.appearance(.light, frame: .all)
        #expect(!off.contains("max-width"))
        #expect(on.contains("max-width"))
        #expect(EntryScripts.appearance(.light, frame: .column).contains("max-width"))
        #expect(!EntryScripts.appearance(.light, frame: .column).contains("var(--xdict-font) !important"))
        #expect(EntryScripts.appearance(.dark, frame: .type).contains("var(--xdict-font) !important"))
        #expect(EntryScripts.appearance(.dark, frame: .type).contains("--xdict-font:"))
        #expect(!EntryScripts.appearance(.light, frame: []).contains("--xdict-font:"))
        #expect(EntryScripts.appearance(.light) == on)
    }

    private func json(_ string: String) throws -> String {
        String(decoding: try JSONEncoder().encode(string), as: UTF8.self)
    }

    /// Q7 (ADR-0010): the text face is the reader's choice, a token switch: Sans by default, Serif the alternative.
    @Test func theFaceIsATokenSwitch() {
        let css = EntryReadingFrame.tokensCSS
        #expect(css.contains(#":root[data-xdict-face=serif]{--xdict-font:ui-serif, "New York", var(--xdict-font-cjk), serif;"#))
        #expect(css.contains(#""Songti SC""#))
        #expect(EntryScripts.appearance(.light, frame: [.column, .type, .serif]).contains("FACE = 'serif'"))
        #expect(EntryScripts.appearance(.light, frame: .all).contains("FACE = 'sans'"))
        #expect(!EntryReadingFrame.all.contains(.serif))
    }

    /// Q3: "Original style" per dictionary, off by default; on, the frame steps aside for that dictionary alone.
    @Test func originalStyleIsPerDictionaryAndOffByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "ReadingFrameTests.\(UUID())"))
        let preferences = EntryPreferences(defaults: defaults)
        #expect(preferences.originalStyle(for: "a") == false)
        preferences.setOriginalStyle(true, for: "a")
        #expect(preferences.originalStyle(for: "a"))
        #expect(preferences.originalStyle(for: "b") == false)
        #expect(EntryReadingFrame.all.applied(originalStyle: true).isEmpty)
        #expect(EntryReadingFrame.all.applied(originalStyle: false) == .all)
    }

    /// No backgrounds anywhere (owner, 2026-10-15): a data table's header row is shown by weight and spacing only.
    @Test func tablesHaveNoFills() {
        let css = EntryReadingFrame.columnCSS
        #expect(!css.contains("nth-child(even)"))
        #expect(!css.contains("background:var(--xdict-panel)"))
        #expect(css.contains("[data-xdict-table=data] th,[data-xdict-table=data] thead td{font-weight:var(--xdict-weight-bold)"))
    }

    /// §5.2–5.5: XDict's speaker, drawn by a CSS mask of an inline SVG in `currentColor`; the dictionary's drawing hidden
    /// in `replace` mode; the accent tag; a 24px hit target that leaves the line box alone.
    @Test func speakersAreDrawnByTheFrame() {
        let css = EntryReadingFrame.controlsCSS()
        #expect(css.contains("[data-xdict-icon=speaker]{"))
        #expect(css.contains("mask-image:url(\"data:image/svg+xml,"))
        #expect(css.contains("background-color:currentColor"))
        #expect(css.contains("[data-xdict-control-mode=replace]>:not([data-xdict-icon]):not([data-xdict-tag]){display:none !important}"))
        #expect(css.contains("[data-xdict-control]::before,[data-xdict-control]::after{content:none !important}"))
        #expect(css.contains("[data-xdict-accent=uk]>[data-xdict-tag]::before{content:"))
        #expect(css.contains("calc((var(--xdict-hit) - 1em) / 2)"))
        #expect(css.contains("[data-xdict-tag]{font-family:var(--xdict-font);"))
        // A tag ends its control with 0.35em of the text before the next control or word (0.56em of the tag's own
        // 0.625em): MED's `UK` touched the next speaker (icon sweep 2026-10-15, §8.4).
        #expect(css.contains("margin-inline-end:0.56em"))
        #expect(!css.contains("url(http"))
        #expect(EntryScripts.appearance(.light, frame: .all).contains("[data-xdict-icon=speaker]"))
        #expect(!EntryScripts.appearance(.light, frame: []).contains("[data-xdict-icon=speaker]"))
    }

    /// The speaker's VoiceOver name: verb first, the same whatever the playing state, from the shell's catalog.
    @Test func speakersAreNamedForVoiceOver() throws {
        let labels = EntryReadingFrame.SpeakerLabels(uk: "Play British pronunciation", us: "Play American pronunciation",
                                                     other: "Play recording", ukTag: "UK", usTag: "US")
        let script = EntryScripts.appearance(.light, frame: .all, labels: labels)
        #expect(script.contains("Play British pronunciation"))
        #expect(script.contains("role"))
        #expect(script.contains("aria-label"))
    }

    /// §1.3: every text token the frame defines (text, text-2, each hue's plain and deep tone) reads at 4.5:1 or more
    /// on every surface it can sit on (the page and the panel), in light and in dark.
    @Test func everyTextTokenReadsOnEverySurface() throws {
        func rgb(_ hex: String) throws -> [Double] {
            let digits = try #require(hex.hasPrefix("#") && hex.count == 7 ? String(hex.dropFirst()) : nil, "\(hex)")
            let value = try #require(Int(digits, radix: 16))
            return [(value >> 16) & 255, (value >> 8) & 255, value & 255].map { Double($0) / 255 }
        }
        func luminance(_ c: [Double]) -> Double {
            let l = c.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
        }
        func contrast(_ a: String, _ b: String) throws -> Double {
            let (x, y) = (luminance(try rgb(a)), luminance(try rgb(b)))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        let table = Dictionary(uniqueKeysWithValues: EntryReadingFrame.colours.map { ($0.0, ($0.1, $0.2)) })
        let surfaces = ["bg", "panel"]
        let texts = EntryReadingFrame.colours.map(\.0).filter {
            !surfaces.contains($0) && !$0.hasSuffix("-tint") && $0 != "rule" && $0 != "plate"
        }
        #expect(texts.count == 18)   // text, text-2, and 8 hues × plain and deep
        for text in texts {
            for surface in surfaces {
                let (tl, td) = try #require(table[text]), (sl, sd) = try #require(table[surface])
                let (light, dark) = (try contrast(tl, sl), try contrast(td, sd))
                #expect(light >= 4.5, "light \(text) on \(surface): \(light)")
                #expect(dark >= 4.5, "dark \(text) on \(surface): \(dark)")
            }
        }
    }
}

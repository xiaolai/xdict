import Foundation
import XDictTokens

/// **The XDict reading frame** (ADR-0010; `dev-docs/reading-style.md`): the shell's stylesheet for the reading surface.
/// It defines the style tokens (§1) per theme and sets the page, the column, the tables' quirks reset, containment and
/// the transcription face. The dictionary's own values become tokens in the core (§1.4), so the frame does not fight
/// them; its `!important`s are on the page alone (R1). Calibration is per edition, in the core: the shell has none.
/// Layers, each switchable on its own, so the gallery can show the dictionary with and without them.
public struct EntryReadingFrame: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The page and the column (R1), containment (R13), images and tables (R10, R16).
    public static let column = EntryReadingFrame(rawValue: 1 << 0)
    /// The body's face, size and leading (R1), and the transcription face (§1.5).
    public static let type = EntryReadingFrame(rawValue: 1 << 1)

    /// The text face the reader chose (ADR-0010 Q7): Sans (the system face, PingFang SC) instead of the default Serif
    /// (New York, Songti SC: Apple's dictionaries' face, parity P18, owner 2026-10-17). A token switch on the root, not a
    /// layer: it changes `--xdict-font`, `--xdict-font-cjk` and `--xdict-font-phon`, nothing else.
    public static let sans = EntryReadingFrame(rawValue: 1 << 2)

    public static let all: EntryReadingFrame = [.column, .type]

    /// "Original style"'s whole frame (ADR-0010 Q3, `reading-style.md` §6): the page's insets, containment, and a light
    /// paper under the dictionary. Never with the other layers.
    public static let minimal = EntryReadingFrame(rawValue: 1 << 3)

    /// The lookup panel's density (R7a, decided 2026-10-17): the tighter role spacing, set A. The main window has the
    /// default, B. A presentation attribute the shell sets for the panel, never inferred from the pane's width.
    public static let panel = EntryReadingFrame(rawValue: 1 << 6)

    /// The page's insets (the reading style's padding tokens), `contain: layout` (R13: nothing pins itself over the
    /// pane), and the paper: the page colour in light, `--xdict-paper` in dark, with `--xdict-paper-text` where the
    /// dictionary sets none. The dictionary's own margins and colours stay its own. XDict's marks draw with the palette;
    /// on the paper they take its light values in dark too.
    static var minimalCSS: String { minimalCSS(.bundled) }
    static func minimalCSS(_ style: EntryStyle) -> String {
        style.css("minimal.css", ["light-palette": colours.map { "--xdict-\($0.0):\($0.1);" }.joined()])
    }

    /// In original style transcriptions draw in the bundled phonetic faces too (a dictionary's own IPA font is often
    /// missing); their colour stays the dictionary's.
    /// `!important`, and on the transcription's own elements: a dictionary's font rule on its class (MWU's) outranks
    /// a plain one. XDict's controls and labels inside keep their own face.
    static var originalPhonCSS: String { originalPhonCSS(.bundled) }
    static func originalPhonCSS(_ style: EntryStyle) -> String { style.css("original-phon.css") }

    /// What a dictionary is shown with: nothing of the frame when the reader chose its "Original style" (ADR-0010 Q3).
    public func applied(originalStyle: Bool) -> EntryReadingFrame { originalStyle ? .minimal : self }

    /// **The accent** every chromatic text colour of the reading style is (owner, 2026-10-16: flatten; teal by
    /// default, the reader's choice in Settings ▸ Reading). The core writes `var(--xdict-accent)`; the shell sets it.
    public enum Accent: String, CaseIterable, Sendable {
        case teal, red, indigo

        /// Light then dark: each at least 7:1 on every surface and tint of the palette, in both themes.
        public var values: (light: String, dark: String) {
            switch self {
            case .teal: Tokens.ReadingStyle.accentTeal
            case .red: Tokens.ReadingStyle.accentRed
            case .indigo: Tokens.ReadingStyle.accentIndigo
            }
        }

        /// Its bit in the frame: none for the default, so a frame without one is teal.
        var bit: EntryReadingFrame {
            switch self {
            case .teal: []
            case .red: EntryReadingFrame(rawValue: 1 << 4)
            case .indigo: EntryReadingFrame(rawValue: 1 << 5)
            }
        }
    }

    static let accentBits = EntryReadingFrame(rawValue: 1 << 4 | 1 << 5)

    /// The accent this frame draws with.
    public var accent: Accent { Accent.allCases.first { !$0.bit.isEmpty && contains($0.bit) } ?? .teal }

    /// This frame with `accent`; only the reading style has one, so Original style's frame is left as it is.
    public func with(accent: Accent) -> EntryReadingFrame {
        guard contains(.type) else { return self }
        return subtracting(Self.accentBits).union(accent.bit)
    }

    /// **The tokens (§1)**: `Tokens/tokens.toml`'s reading-style groups, generated into `Style/tokens.css` (`:root`),
    /// `Style/palette.css` (per theme and accent hue) and `Style/density.css` (R7a), and into `Tokens.ReadingStyle` as
    /// data. Names are fixed by the spec; values are the gallery's to tune, in the source (`Tools/tokens.py`).
    static var tokens: [(String, String)] { Tokens.ReadingStyle.root }

    /// SIL 7.000 renamed Charis SIL and Gentium Plus; the new names first, the old for an earlier install.
    static let phonFallbacks = #""Charis", "Charis SIL", "Doulos SIL", "Gentium", "Gentium Plus", var(--xdict-font)"#

    /// §1.3: surfaces, text, and eight hue families × deep / plain / tint, light then dark (the source says why each
    /// is what it is: the neutrals and the link are the system's, P26, P27).
    static var colours: [(String, String, String)] { Tokens.ReadingStyle.palette }

    /// The palette alone, per theme: what the core's colour tokens need even with no frame ("Original style").
    static var paletteCSS: String { paletteCSS(.bundled) }
    static func paletteCSS(_ style: EntryStyle) -> String { style.css("palette.css") }

    static var tokensCSS: String { tokensCSS(.bundled) }
    static func tokensCSS(_ style: EntryStyle) -> String {
        EntryFonts.fontFaceCSS + style.css("tokens.css") + paletteCSS(style)
            + #":root[data-xdict-face=sans]{--xdict-font:-apple-system, "Helvetica Neue", var(--xdict-font-cjk), sans-serif;"#
            + #"--xdict-font-cjk:"PingFang SC", "Hiragino Sans GB";--xdict-font-phon:"\#(EntryFonts.sans)", \#(phonFallbacks)}"#
            + ":lang(zh-Hant){--xdict-font-cjk:\"PingFang TC\"}:lang(ja){--xdict-font-cjk:\"Hiragino Sans\"}"
            + ":lang(ko){--xdict-font-cjk:\"Apple SD Gothic Neo\"}"
    }

    /// R1, R10, R13, R16. The page's properties win by `!important` (the core drops the dictionary's page rules); the
    /// column is the measure plus the inline padding. The quirks-mode table reset is undone, so a table's text is the
    /// scale's. Data tables scroll in the core's wrapper; only an unwrapped one scrolls itself. `contain: layout` makes
    /// the body the containing block of a dictionary's `position: fixed`, so nothing pins itself over the pane.
    static var columnCSS: String { columnCSS(.bundled) }
    static func columnCSS(_ style: EntryStyle) -> String { style.css("column.css") }

    /// XDict's speaker (§5.5): its own drawing, a speaker with two waves, as an inline SVG mask filled with the text's
    /// colour, so it follows the theme, the link colour and hover. No URL but `data:`, which the policy already allows.
    static let speakerSVG = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'>"
        + "<path d='M1.5 5.5h3l4-3.2v11.4l-4-3.2h-3z'/>"
        + "<path d='M10.6 5.2a3.6 3.6 0 0 1 0 5.6' fill='none' stroke='black' stroke-width='\(Tokens.EntryText.glyphStroke)' stroke-linecap='round'/>"
        + "<path d='M12.4 3a6.6 6.6 0 0 1 0 10' fill='none' stroke='black' stroke-width='\(Tokens.EntryText.glyphStroke)' stroke-linecap='round'/>"
        + "</svg>"

    static var speakerMask: String { mask(speakerSVG) }

    /// An inline SVG as a CSS `url()` of a `data:` URL.
    static func mask(_ svg: String) -> String {
        let encoded = svg.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "#", with: "%23")
        return "url(\"data:image/svg+xml,\(encoded)\")"
    }

    /// §5.2–5.5: the speaker controls the core marks. The dictionary's drawing stays in the bytes, hidden in `replace`
    /// mode; the glyph is 1em of the text it sits in; the hit target reaches `--xdict-hit` by padding and an equal
    /// negative margin, so the line box does not move; the accent tag is small caps after the glyph.
    static func controlsCSS(ukTag: String = "UK", usTag: String = "US", style: EntryStyle = .bundled) -> String {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "") + "\"" }
        return style.css("controls.css", ["speaker-mask": speakerMask, "uk-tag": quoted(ukTag), "us-tag": quoted(usTag)])
    }

    /// The speakers' VoiceOver names and accent tags, in the reader's language (§5.2: verb first, the same whatever
    /// the playing state). The shell's runtime sets them, in its own world.
    public struct SpeakerLabels: Sendable, Equatable {
        public var uk, us, other, ukTag, usTag: String
        public init(uk: String, us: String, other: String, ukTag: String, usTag: String) {
            (self.uk, self.us, self.other, self.ukTag, self.usTag) = (uk, us, other, ukTag, usTag)
        }

        public static var localized: SpeakerLabels {
            SpeakerLabels(uk: String(localized: EntrySentences.speakerUK), us: String(localized: EntrySentences.speakerUS),
                          other: String(localized: EntrySentences.speakerOther),
                          ukTag: String(localized: EntrySentences.accentTagUK),
                          usTag: String(localized: EntrySentences.accentTagUS))
        }
    }

    /// R1's body face, size and leading; the transcription face (§1.5). Inside a transcription XDict's text face is
    /// the phonetic face, so a dictionary rule the core set to `var(--xdict-font)` there (OALD's, MWU's) draws in it
    /// too; no cycle, as `--xdict-font-phon` is declared on the root alone and arrives here resolved. Unification R
    /// (owner, 2026-10-16; `dev-docs/artifacts/reading-frame/unify/` §11): what the browser's own sheet sizes and
    /// spaces is put on the scale and the space tokens, and the three strong roles win over their descendants'
    /// normalized declarations from a cascade layer; a transcription keeps its colour.
    static var typeCSS: String { typeCSS(.bundled) }
    static func typeCSS(_ style: EntryStyle) -> String { style.css("type.css") + style.css("density.css") }
}

extension EntryScripts {
    /// The gallery's arithmetic, with no DOM: the entry's dominant text size, the size most of its characters are set
    /// in. A measurement only; nothing on the page is scaled by it.
    static var frameCore: String { EntryStyle.bundled.script("frame-core.js") }

    /// The frame on the page, in the shell's world: the theme attribute, the tokens and the layers' stylesheets, put
    /// back if a page script removes or rewrites them. `__xdictFrame.measure()` reports what the gallery compares.
    static func frameDOM(_ frame: EntryReadingFrame, scheme: EntryColourScheme,
                         labels: EntryReadingFrame.SpeakerLabels, style: EntryStyle = .bundled) -> String {
        let controls = EntryReadingFrame.controlsCSS(ukTag: labels.ukTag, usTag: labels.usTag, style: style)
        let column = frame.contains(.column)
            ? EntryReadingFrame.columnCSS(style) + controls + EntryReadingFrame.marksCSS(style)
                + EntryReadingFrame.readingLabelsCSS(style) : ""
        let names = ["uk": labels.uk, "us": labels.us, "other": labels.other]
        let tokenNames = (EntryReadingFrame.colours.map(\.0) + ["phon-colour"]).map { "\"\($0)\"" }.joined(separator: ",")
        let namesJSON = (try? JSONSerialization.data(withJSONObject: !frame.isDisjoint(with: [.column, .minimal]) ? names : [:], options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let type = frame.contains(.type) ? EntryReadingFrame.typeCSS(style) : ""
        // "Original style": the minimal frame and XDict's whole marks layer (the owner, 2026-10-16), no column or type.
        let minimal = frame.contains(.minimal)
            ? EntryReadingFrame.minimalCSS(style) + controls + EntryReadingFrame.marksCSS(style)
                + EntryReadingFrame.originalPhonCSS(style) : ""
        let tokens = (frame.subtracting([.sans, EntryReadingFrame.accentBits]).isEmpty ? EntryReadingFrame.paletteCSS(style) : EntryReadingFrame.tokensCSS(style))
            + (frame.contains(.panel) ? EntryReadingFrame.popoverColoursCSS : "")
        return style.script("frame.js", [
            "theme": scheme.rawValue, "face": frame.contains(.sans) ? "sans" : "serif", "hue": frame.accent.rawValue,
            "sheet-tokens": jsString(tokens), "sheet-column": jsString(column), "sheet-type": jsString(type),
            "sheet-minimal": jsString(minimal), "names": namesJSON, "token-names": tokenNames,
            "space-cap": frame.contains(.type) ? "0.25" : "0",
            "label": frame.contains(.type) ? "[data-xdict-role=label]" : "",
            "pictures": jsString(String(localized: EntrySentences.pictures)),
            "density": frame.contains(.panel) ? "panel" : "main",
        ])
    }

    /// A JavaScript string literal for `text`, by JSON's own escaping.
    private static func jsString(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}

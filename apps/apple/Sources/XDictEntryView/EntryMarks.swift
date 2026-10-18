import Foundation
import XDictTokens

/// **XDict's marks** (icon sweep 2026-10-15 §8; ADR-0010): the core marks what a dictionary drew, the frame draws XDict's
/// own in its place. Glyphs are CSS masks of inline `data:` SVG filled with `currentColor` (no route, no script); labels
/// are the core's text in one style; colours and sizes are tokens only.
extension EntryReadingFrame {
    /// A chevron to the trailing side, turned down when its fold is open (§8.1 `disclosure`).
    static let chevronSVG = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'>"
        + "<path d='M6 3.5l4.5 4.5L6 12.5' fill='none' stroke='black' stroke-width='\(Tokens.EntryText.glyphStroke)' stroke-linecap='round' "
        + "stroke-linejoin='round'/></svg>"

    /// An arrow to the trailing side (§8.1 `lookup`).
    static let arrowSVG = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'>"
        + "<path d='M2.5 8h10.5M9.5 4.5L13 8l-3.5 3.5' fill='none' stroke='black' stroke-width='\(Tokens.EntryText.glyphStroke)' "
        + "stroke-linecap='round' stroke-linejoin='round'/></svg>"

    /// A glyph box: 1em of the text it sits in, painted by `svg` as a mask in the text's colour.
    private static func glyph(_ svg: String) -> String {
        "content:\"\" !important;display:inline-block !important;width:var(--xdict-icon) !important;"
            + "height:var(--xdict-icon) !important;vertical-align:var(--xdict-glyph-baseline) !important;position:static !important;"
            + "float:none !important;font-size:inherit !important;border:0 !important;box-shadow:none !important;"
            + "background-color:currentColor !important;-webkit-mask:\(mask(svg)) center/contain no-repeat !important;"
            + "mask:\(mask(svg)) center/contain no-repeat !important"
    }

    /// Labels in the secondary colour with no box (R11): every label in the reading style.
    static var readingLabelsCSS: String { readingLabelsCSS(.bundled) }
    static func readingLabelsCSS(_ style: EntryStyle) -> String { style.css("reading-labels.css") }

    /// The marks' rules, after the controls' (`controlsCSS`), in the column layer.
    static var marksCSS: String { marksCSS(.bundled) }
    static func marksCSS(_ style: EntryStyle) -> String {
        style.css("marks.css", ["glyph-arrow": glyph(arrowSVG), "glyph-chevron": glyph(chevronSVG)])
    }
}

extension EntryScripts {
    /// The disclosure state, with no DOM: each fold head's `aria-expanded` is whether the element it folds is shown. The
    /// folded element is the one `aria-controls` names, else the next element after the head, or after a wrapper of it
    /// (up to two levels: a title span inside a box's head). No folded element: no state is claimed. Writes only on a
    /// change, and at most `MAX` heads a pass.
    static var disclosureCore: String { EntryStyle.bundled.script("disclosure-core.js") }

    /// The disclosure state on the page, in the shell's world: synced after load, after any change of a class, style,
    /// `hidden` or `open` (debounced), and after every click, once the page's own handlers have run. It writes only
    /// `aria-expanded` and `role`, which no fold script reads, and never handles a click, so the dictionary's fold
    /// script works as it always did. `__xdictDisclosure.expand(open)` clicks every head not yet in that state, as a
    /// reader would, and answers how many it clicked: "Expand All" and "Collapse All".
    static var disclosureDOM: String { EntryStyle.bundled.script("disclosure.js") }

    /// **A speaker and the transcription it plays stay on one line** (CALD "remember sb to sb" broke between them):
    /// the run from a speaker, through blanks and other speakers, to the next sibling transcription. No DOM: `is`
    /// says what a node is, so the rule is tested alone. `null` when anything else comes first.
    static var pronRunCore: String { EntryStyle.bundled.script("pron-run-core.js") }

    /// The run on the page, in the shell's world: wrapped once in `data-xdict-pron-run`, which the marks keep from
    /// breaking (the break goes before the speaker); the transcription inside still wraps within itself.
    static var pronRunDOM: String { EntryStyle.bundled.script("pron-run.js") }
}

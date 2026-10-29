import Foundation
import XDictTokens

/// **The shell's own scripts, in a content world of their own** (`EntryPane.world`): the page cannot see their globals,
/// replace their functions or call their message handler. They make no request and change no URL: find (R3), the
/// readability rule (R4), and a reader's click on a blocked image's placeholder. Each pure part is its own object with
/// no DOM, so `swift test` runs it in JavaScriptCore without a web view.
enum EntryScripts {
    /// **The entry's language on its document** (owner, 2026-10-29; `note-cjk-typography-2026-10-29.md`): the dictionary's
    /// declared code, which the reading style's `:lang(zh)` turns into Chinese leading. Set at document start, before the
    /// style is applied, so nothing is laid out twice; the code is encoded as JSON — never spliced into the script — and a
    /// code that is not one leaves the document alone.
    static func language(_ code: String?) -> String? {
        guard let code, !code.isEmpty,
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return "document.documentElement.lang=\"\(code)\";"
    }

    /// **The reader's Chinese face, on the root** (owner, 2026-10-29): `--xdict-font-cjk` set inline, which beats the
    /// style's own `:root` value, exactly as the accent does with the frame. The style's own face needs no override; a
    /// face the Mac cannot draw is refused here rather than resolving to the Latin substitute a missing name becomes.
    static func chineseFace(_ face: EntryChineseFace?) -> String? {
        guard let face, face != .songti, face.isInstalled else { return nil }
        let data = try? JSONEncoder().encode(face.stack)
        guard let data, let list = String(data: data, encoding: .utf8) else { return nil }
        return "document.documentElement.style.setProperty(\"--xdict-font-cjk\", \(list));"
    }

    /// The reading inset every entry gets, whatever its CSS: many MDict stylesheets say `body{margin:0}`, as GoldenDict
    /// pads its articles itself. On the root and `!important`, so neither a body margin nor a plain `html{padding:0}`
    /// removes it; the dictionary's full-width rows end at it like a page margin, and the scroller stays at the edge.
    static let readingInset = "html{padding:\(Tokens.EntryText.readingInset) !important;box-sizing:border-box}"
    /// Find's matching, with no DOM: whitespace in the query matches any run of whitespace, letters match whatever
    /// their case (Unicode simple folding), everything else as written.
    static var findCore: String { EntryStyle.bundled.script("find-core.js") }

    /// Find over the document: the text the reader can see and the text folded away (an ancestor with no box, or
    /// `visibility: hidden`) are read apart, each as one string with a line break wherever a block or `<br>` breaks the
    /// flow, as `innerText` reads it. Visible matches are highlighted and stepped through; hidden ones only counted.
    static var findDOM: String { EntryStyle.bundled.script("find.js") }

    /// Contrast arithmetic, with no DOM: WCAG's contrast ratio, for the gallery's measurement (`frameDOM`'s `measure`).
    /// It corrects nothing: the palette's tokens read on every surface by construction (`colour.rs`).
    static var readabilityCore: String { EntryStyle.bundled.script("readability-core.js") }

    /// The page drawn light or dark (`EntryColourScheme`), at document start with the scheme baked in so nothing
    /// flashes; then the frame, and the guard over the colours the page's own scripts write (`colourGuard`). No colour
    /// is corrected here: the core and the palette own colour (ADR-0010).
    static func appearance(_ scheme: EntryColourScheme, frame: EntryReadingFrame = .all,
                           labels: EntryReadingFrame.SpeakerLabels = .localized, style: EntryStyle = .bundled) -> String {
        style.script("frame-core.js") + "\n" + frameDOM(frame, scheme: scheme, labels: labels, style: style) + "\n"
            + colourCore(style) + "\n" + style.script("colour-guard.js") + "\n"
            + style.script("appearance.js", ["theme": scheme.rawValue, "inset": readingInset])
    }

    /// The name of the one message handler, registered in the shell's world only.
    /// Where an entry lands once loaded (`EntryLanding`), as a function body run in the shell's world with the place as
    /// an argument, never spliced into the text: `y` an offset, `a` an anchor's id or name. Nil for the top, where a new
    /// document already is.
    static func landing(_ landing: EntryLanding) -> (body: String, arguments: [String: Any])? {
        switch landing {
        case .top:
            return nil
        case .offset(let y):
            return ("window.scrollTo(0, y); return window.scrollY;", ["y": y])
        case .anchor(let a):
            return ("""
                var e = document.getElementById(a) || document.getElementsByName(a)[0];
                if (e) e.scrollIntoView();
                return window.scrollY;
                """, ["a": a])
        }
    }

    /// How far down the entry the reader has scrolled, in CSS pixels.
    static let scrollOffset = "return window.scrollY;"
    /// The shown document's content height in CSS pixels: what the lookup panel sizes itself to (UI review P-03). Not
    /// `documentElement.scrollHeight`, which is never less than the viewport: in a 440 pt panel a one-line entry
    /// measured the panel itself, and the panel never shrank. The body's contents, to their last line, plus the
    /// body's bottom padding and margin.
    static let documentHeight = """
        const body = document.body; if (!body) { return null; }
        const range = document.createRange(); range.selectNodeContents(body);
        const style = getComputedStyle(body);
        return Math.ceil(range.getBoundingClientRect().bottom + window.scrollY
            + parseFloat(style.paddingBottom || "0") + parseFloat(style.marginBottom || "0"));
        """

    static let handlerName = "xdictEntry"

    /// The shell's scripts, in the order they are installed at document start, before any of the page's. The display
    /// options' script comes first, so the root holds the shell's values before anything else runs.
    static func installed(_ scheme: EntryColourScheme, frame: EntryReadingFrame, style: EntryStyle = .bundled,
                          display: EntryDisplayOptions = .none, values: [EntryDisplayValue] = [],
                          language: String? = nil, chineseFace: EntryChineseFace? = nil) -> [String] {
        [Self.language(language), Self.display(display, values: values, style: style), Self.chineseFace(chineseFace)]
            .compactMap { $0 }
            + [style.script("find-core.js"), style.script("find.js"), style.script("readability-core.js"),
               appearance(scheme, frame: frame, style: style), style.script("placeholder-clicks.js"),
               style.script("speaker-clicks.js"), style.script("disclosure-core.js"), style.script("disclosure.js"),
               style.script("pron-run-core.js"), style.script("pron-run.js"), style.script("word-clicks-core.js"),
               style.script("word-clicks.js"), style.script("sense-clicks-core.js"), style.script("sense-clicks.js"),
               style.script("hover-word.js")]
    }

    /// **The word under a hover point, for hover in XDict's own window** (`EntryWebView.hoverText`): after the word
    /// core it uses; it reads, never writes.
    static var hoverWord: String { EntryStyle.bundled.script("hover-word.js") }

    /// Asks it, in the shell's world, at CSS pixel (`x`, `y`) for at most `m` UTF-16 units.
    static let askHoverWord = "return window.__xdictHoverWord ? window.__xdictHoverWord(x, y, m) : null"

    /// **The entry's selection, for the lookup shortcut, the menu and the Service in XDict's own window**
    /// (`EntryWebView.selectionText`), in the shell's world: the text around it too where `s`, at most `m` UTF-16 units.
    static let askSelectionText = "return window.__xdictSelectionText ? window.__xdictSelectionText(s, m) : null"

    /// **A dictionary's display options** (ADR-0013 d.3): the root given `values`, the default included, and the core's
    /// CSS installed with them, from the shell's world. The values and the CSS travel as one JSON literal, never as
    /// script text; nil when the edition declares nothing.
    static func display(_ options: EntryDisplayOptions, values: [EntryDisplayValue], style: EntryStyle = .bundled) -> String? {
        guard !options.options.isEmpty else { return nil }
        let given: [String: Any] = ["values": values.map { [$0.attribute, $0.value] }, "css": options.css]
        guard let json = try? JSONSerialization.data(withJSONObject: given, options: [.sortedKeys]),
              let literal = String(data: json, encoding: .utf8) else { return nil }
        return style.script("display-options.js", ["given": literal])
    }

    /// The live change (ADR-0013 d.3): the shown document's root given new values in place, answered with what it holds.
    static let setDisplay = "return window.__xdictDisplay ? window.__xdictDisplay.set(v) : null"

    /// **A click on XDict's speaker is XDict's** (the core marks it `data-xdict-control="speaker"`): on the window, in
    /// the capture phase, installed before any page script, so it runs first. It stops the click going further into
    /// the page, whose own handler would otherwise cancel it and play the recording itself (COBUILD's, from an `addr`
    /// XDict never serves), and leaves the default alone: the link's navigation, which the router answers. Untrusted
    /// clicks too: a page's or an instrument's `click()` on a speaker means the same. Every other click is the page's.
    static var speakerClicks: String { EntryStyle.bundled.script("speaker-clicks.js") }

    /// A reader's click on a blocked image's placeholder asks the same question as a remote link. Trusted clicks only:
    /// a script's `click()` or `dispatchEvent` is not the reader. An image inside a link is left to the link.
    static var placeholderClicks: String { EntryStyle.bundled.script("placeholder-clicks.js") }

    /// **A click on a sense selects it** (plan-explain-sense WI-5; ADR-0029): the ordinal's own bounds and uniqueness,
    /// and which clicks are the reader's, with no DOM — so `swift test` runs it in JavaScriptCore.
    static var senseClicksCore: String { EntryStyle.bundled.script("sense-clicks-core.js") }

    /// The DOM side: the nearest `data-xdict-sense` ancestor of the clicked element, its ordinal sent alone. The text
    /// is the core's projection, never this page's.
    static var senseClicksDOM: String { EntryStyle.bundled.script("sense-clicks.js") }

    /// The word under a caret, by the segmenter's word granularity and trimmed of punctuation, and whether a click may
    /// open it in a new tab: with no DOM, so `swift test` runs it in JavaScriptCore (parity P47).
    static var wordClicksCore: String { EntryStyle.bundled.script("word-clicks-core.js") }

    /// **A ⌘-click on a word opens its lookup in a new tab** (P47): the reader's single ⌘-click only (trusted, nothing
    /// selected, no drag, not taken by the page), never inside a link or a control, posts `{kind: "word", word}` once.
    /// A plain click does nothing new (owner, 2026-10-18).
    static var wordClicksDOM: String { EntryStyle.bundled.script("word-clicks.js") }
}

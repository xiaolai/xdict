import Foundation

/// **The shell's own scripts, in a content world of their own** (`EntryPane.world`): the page cannot see their globals,
/// replace their functions or call their message handler. They make no request and change no URL: find (R3), the
/// readability rule (R4), and a reader's click on a blocked image's placeholder. Each pure part is its own object with
/// no DOM, so `swift test` runs it in JavaScriptCore without a web view.
enum EntryScripts {
    /// The reading inset every entry gets, whatever its CSS: many MDict stylesheets say `body{margin:0}`, as GoldenDict
    /// pads its articles itself. On the root and `!important`, so neither a body margin nor a plain `html{padding:0}`
    /// removes it; the dictionary's full-width rows end at it like a page margin, and the scroller stays at the edge.
    static let readingInset = "html{padding:8px 14px !important;box-sizing:border-box}"
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

    /// The shell's scripts, in the order they are installed at document start, before any of the page's.
    static func installed(_ scheme: EntryColourScheme, frame: EntryReadingFrame, style: EntryStyle = .bundled) -> [String] {
        [style.script("find-core.js"), style.script("find.js"), style.script("readability-core.js"),
         appearance(scheme, frame: frame, style: style), style.script("placeholder-clicks.js"),
         style.script("speaker-clicks.js"), style.script("disclosure-core.js"), style.script("disclosure.js"),
         style.script("pron-run-core.js"), style.script("pron-run.js")]
    }

    /// **A click on XDict's speaker is XDict's** (the core marks it `data-xdict-control="speaker"`): on the window, in
    /// the capture phase, installed before any page script, so it runs first. It stops the click going further into
    /// the page, whose own handler would otherwise cancel it and play the recording itself (COBUILD's, from an `addr`
    /// XDict never serves), and leaves the default alone: the link's navigation, which the router answers. Untrusted
    /// clicks too: a page's or an instrument's `click()` on a speaker means the same. Every other click is the page's.
    static var speakerClicks: String { EntryStyle.bundled.script("speaker-clicks.js") }

    /// A reader's click on a blocked image's placeholder asks the same question as a remote link. Trusted clicks only:
    /// a script's `click()` or `dispatchEvent` is not the reader. An image inside a link is left to the link.
    static var placeholderClicks: String { EntryStyle.bundled.script("placeholder-clicks.js") }
}

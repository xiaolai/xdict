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

    /// SIL's 7.000 fonts renamed "Charis SIL" to "Charis" and "Gentium Plus" to "Gentium": both names are asked for, the
    /// new first, so either installed version sets the transcriptions.
    @Test func thePhoneticFontsAreNamedOldAndNew() {
        #expect(EntryReadingFrame.tokensCSS.contains(
            #"--xdict-font-phon:"XDict Phonetic Sans", "Charis", "Charis SIL", "Doulos SIL", "Gentium", "Gentium Plus", var(--xdict-font);"#))
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
        #expect(EntryReadingFrame.all.applied(originalStyle: true) == .minimal)
        #expect(EntryReadingFrame.all.applied(originalStyle: false) == .all)
    }

    /// Switching "Original style" changes the core's rendering, so the entry is fetched again; any other frame change
    /// only reloads what is in memory.
    @Test func switchingOriginalStyleFetchesTheEntryAgain() {
        #expect(EntryPane.restyles(from: .all, to: .minimal))
        #expect(EntryPane.restyles(from: .minimal, to: .all))
        #expect(!EntryPane.restyles(from: .all, to: [.column, .type, .serif]))
    }

    /// Q3, `reading-style.md` §6: "Original style" keeps a minimal frame: the page's insets and containment, and a
    /// light paper under the dictionary, whose colours assume white, in dark too. No column, type or controls, and no
    /// colour of the dictionary's is touched.
    @Test func originalStyleKeepsAMinimalFrameOnLightPaper() {
        let css = EntryReadingFrame.minimalCSS
        #expect(css.contains("contain:layout"))
        #expect(css.contains("padding:"))
        #expect(css.contains(":root[data-xdict-theme=dark]{background:\(EntryReadingFrame.paper)"))
        #expect(css.contains(":root[data-xdict-theme=light]{background:#ffffff"))
        #expect(!css.contains("max-width"), "the column is the reading style's")
        let dark = EntryScripts.appearance(.dark, frame: .minimal)
        #expect(dark.contains("xdict-frame-minimal"))
        #expect(!EntryScripts.appearance(.dark, frame: .all).contains(EntryReadingFrame.minimalCSS))
        // The owner (2026-10-16): XDict's whole marks layer comes with it (labels, speakers, folds), the type and the
        // column do not.
        #expect(dark.contains("[data-xdict-icon=speaker]"), "XDict's speaker")
        #expect(dark.contains("[data-xdict-role=label]{"), "XDict's labels")
        // The bundled phonetic faces (macos-v1 ab1525f) draw transcriptions in original style too; the colour stays
        // the dictionary's.
        #expect(dark.contains("@font-face"), "the bundled faces")
        // A label of the dictionary's words keeps its own colour in original style; the reading style greys them all.
        #expect(!dark.contains(EntryReadingFrame.readingLabelsCSS))
        #expect(EntryScripts.appearance(.dark, frame: .all).contains(EntryReadingFrame.readingLabelsCSS))
        #expect(dark.contains(EntryReadingFrame.originalPhonCSS))
        #expect(EntryReadingFrame.originalPhonCSS.contains("font-family:var(--xdict-font-phon) !important"))
        #expect(dark.contains("[data-xdict-labelled]{display:none !important}"), "the badges the labels replace, hidden")
        #expect(dark.contains("[data-xdict-control=disclosure]"), "XDict's fold signs")
        #expect(!dark.contains(EntryReadingFrame.typeCSS), "XDict's type is the reading style's")
        #expect(!dark.contains("max-width:calc(var(--xdict-measure)"), "XDict's column is the reading style's")
        // On the paper, the marks take the light palette in dark too, or a dark theme's pale link would sit on paper.
        #expect(css.contains(":root[data-xdict-theme=dark]{--xdict-bg:#ffffff;"))
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
        #expect(css.contains("[data-xdict-tag]{font-family:var(--xdict-font-text);"))
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

    // MARK: - XDict's marks (icon sweep §8): the core marks, the frame draws.

    /// Every `var(--xdict-…)` the marks use is a token the frame defines, and no colour is written as a literal.
    @Test func theMarksUseTokensOnly() throws {
        let css = EntryReadingFrame.marksCSS
        let defined = Set(EntryReadingFrame.tokens.map(\.0) + EntryReadingFrame.colours.map(\.0))
        let used = try Regex(#"var\(--xdict-([a-z0-9-]+)\)"#)
        var names: [String] = []
        for match in css.matches(of: used) { names.append(String(css[match.range]).dropFirst(12).dropLast().description) }
        #expect(!names.isEmpty)
        for name in names { #expect(defined.contains(name), "\(name)") }
        #expect(!css.contains("rgb("))
        #expect(css.range(of: #"#[0-9a-fA-F]{3,6}\b"#, options: .regularExpression) == nil)
        #expect(!css.contains("url(http"))
    }

    /// Each rule of §8 exists: the disclosure chevron turned by `aria-expanded`, the lookup arrow on either side, the
    /// one marker, the labels, plain sense numbers, and hidden graphics kept hidden.
    @Test func eachMarkHasItsRule() {
        let css = EntryReadingFrame.marksCSS
        #expect(css.contains("[data-xdict-control=disclosure]::before{content:\"\" !important;"))
        #expect(css.contains("[data-xdict-control=disclosure][aria-expanded=true]::before{transform:rotate(90deg) !important}"))
        #expect(css.hasPrefix("@layer xdict-marks{[data-xdict-before]::before"), "layered, so no unlayered !important outranks it")
        #expect(css.contains("[data-xdict-before=lookup]::before,[data-xdict-after=lookup]::after{content:\"\" !important;"))
        #expect(css.contains("[data-xdict-before=marker]::before,[data-xdict-after=marker]::after{content:\"\" !important;"))
        #expect(css.contains("background-color:var(--xdict-text-2) !important;border-radius:50%"))
        #expect(css.contains("[data-xdict-role=label]{"))
        for kind in ["level", "wordlist", "frequency", "new"] {
            #expect(css.contains("[data-xdict-role=label][data-xdict-label=\(kind)]"), "\(kind)")
        }
        #expect(css.contains("[data-xdict-role=sensenum]{"))
        #expect(css.contains("[data-xdict-labelled]{display:none !important}"))
        #expect(css.contains(":dir(rtl)"))
        #expect(EntryScripts.appearance(.light, frame: .all).contains("[data-xdict-role=label]"))
        #expect(!EntryScripts.appearance(.light, frame: []).contains("[data-xdict-role=label]"))
    }

    /// Where the core marked a pseudo-element, the dictionary's `content` is cleared first, background drawings with
    /// it, and only XDict's empty box is drawn after; `drop` draws nothing at all.
    @Test func noDictionaryContentSurvivesOnAMarkedElement() {
        let css = EntryReadingFrame.marksCSS
        let clear = "[data-xdict-before]::before,[data-xdict-after]::after{content:none !important;"
            + "background-image:none !important"
        let clearAt = css.range(of: clear)
        #expect(clearAt != nil)
        for drawn in ["[data-xdict-before=lookup]::before", "[data-xdict-before=marker]::before",
                      "[data-xdict-control=disclosure]::before{"] {
            let at = css.range(of: drawn)
            #expect(at != nil, "\(drawn)")
            if let at, let clearAt { #expect(clearAt.lowerBound < at.lowerBound, "\(drawn) comes after the clearing") }
        }
        #expect(!css.contains("=drop]"))
        // XDict's own drawings are the only content written, and they are empty boxes painted by a mask or a fill.
        let contents = css.components(separatedBy: "content:").dropFirst().map { String($0.prefix(while: { $0 != ";" && $0 != "}" })) }
        for value in contents { #expect(value == "none !important" || value == "\"\" !important", "\(value)") }
        // The generic controls' layout leaves a fold head's own block alone.
        #expect(EntryReadingFrame.controlsCSS().contains("[data-xdict-control]:not([data-xdict-control=disclosure]){"))
    }

    static func disclosure() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
        context.evaluateScript(EntryScripts.disclosureCore)
        // A minimal element: attributes, a sibling and a parent, and whether it is shown.
        context.evaluateScript("""
            function El(shown) { this.attrs = {}; this.shown = shown; this.nextElementSibling = null; this.parentElement = null; }
            El.prototype.getAttribute = function (n) { return n in this.attrs ? this.attrs[n] : null; };
            El.prototype.setAttribute = function (n, v) { this.attrs[n] = String(v); };
            var byId = {}; function find(id) { return byId[id] || null; }
            function shown(e) { return e.shown; }
            """)
        return context
    }

    /// The chevron follows the fold: `aria-expanded` is the computed state of the element the head controls (named by
    /// `aria-controls`, else the next element after the head or after its wrapper), set only when it changes.
    @Test func theDisclosureStateFollowsAToggledElement() throws {
        let context = try Self.disclosure()
        func run(_ js: String) -> String? { context.evaluateScript(js)?.toString() }
        _ = run("""
            var head = new El(true), body = new El(false); head.nextElementSibling = body;
            var wrapped = new El(true), wrapper = new El(true), after = new El(true);
            wrapped.parentElement = wrapper; wrapper.nextElementSibling = after;
            var named = new El(true), far = new El(false); named.setAttribute('aria-controls', 'x'); byId.x = far;
            named.nextElementSibling = new El(true);
            var alone = new El(true);
            var all = [head, wrapped, named, alone];
            """)
        #expect(run("XDictDisclosureCore.sync(all, find, shown)") == "3")
        #expect(run("head.getAttribute('aria-expanded')") == "false")
        #expect(run("wrapped.getAttribute('aria-expanded')") == "true")
        #expect(run("named.getAttribute('aria-expanded')") == "false", "aria-controls wins over the sibling")
        #expect(run("alone.getAttribute('aria-expanded')") == "null", "no folded element: no state claimed")
        // The dictionary's own script opens the fold: the state follows; nothing else is written.
        _ = run("body.shown = true; far.shown = true;")
        #expect(run("XDictDisclosureCore.sync(all, find, shown)") == "2")
        #expect(run("head.getAttribute('aria-expanded')") == "true")
        #expect(run("named.getAttribute('aria-expanded')") == "true")
        #expect(run("XDictDisclosureCore.sync(all, find, shown)") == "0", "unchanged state writes nothing")
        _ = run("body.shown = false;")
        #expect(run("XDictDisclosureCore.sync(all, find, shown)") == "1")
        #expect(run("head.getAttribute('aria-expanded')") == "false")
    }

    /// The work is bounded: a page with more fold heads than the cap syncs the cap and no more.
    @Test func theDisclosureWorkIsBounded() throws {
        let context = try Self.disclosure()
        let max = try #require(context.evaluateScript("XDictDisclosureCore.MAX")?.toInt32())
        #expect(max > 0)
        let synced = context.evaluateScript("""
            var many = []; for (var i = 0; i < \(max) + 50; i++) { var h = new El(true); h.nextElementSibling = new El(true); many.push(h); }
            XDictDisclosureCore.sync(many, find, shown)
            """)?.toInt32()
        #expect(synced == max)
    }

    /// The disclosure scripts are the shell's in every view, Original style included, so "Expand All" works there too.
    @Test func theDisclosureScriptsAreInstalled() {
        for frame in [EntryReadingFrame.all, []] {
            let installed = EntryScripts.installed(.light, frame: frame)
            #expect(installed.contains(EntryScripts.disclosureCore))
            #expect(installed.contains(EntryScripts.disclosureDOM))
        }
        #expect(EntryScripts.disclosureDOM.contains("__xdictDisclosure"))
        #expect(EntryScripts.disclosureDOM.contains("MutationObserver"))
    }

    /// The coordinator's review of oald-long (2026-10-16), as rules in the marks' layer, so no unlayered `!important`
    /// of the dictionary's outranks them: a round dot whatever box the dictionary gave its pseudo-element; the speaker
    /// one inline row with its tag first on the baseline; labels sized by their text; punctuation hugged; fold heads at
    /// the block gap.
    @Test func theMarksHoldTheirBoxes() throws {
        let css = EntryReadingFrame.marksCSS
        let layer = try #require(css.range(of: "@layer xdict-marks{"))
        let layered = String(css[layer.upperBound...])
        func inLayer(_ rule: String) -> Bool { layered.contains(rule) }
        #expect(inLayer("padding:0 !important;aspect-ratio:1 !important;"), "the marker is round")
        #expect(inLayer("[data-xdict-control=speaker]{display:inline-flex !important;align-items:center !important;"
                        + "width:auto !important;height:auto !important;"))
        #expect(inLayer("[data-xdict-control=speaker]>[data-xdict-tag]{order:-1 !important;"))
        #expect(inLayer("[data-xdict-role=label][data-xdict-label=level],"))
        #expect(inLayer("{display:inline !important;width:auto !important;height:auto !important;"))
        #expect(inLayer("[data-xdict-hug],[data-xdict-hug] :last-child:not([data-xdict-tag]),"
                        + "[data-xdict-hug] [data-xdict-role=label]:has(+ [data-xdict-labelled]:last-child)"
                        + "{margin-inline-end:0 !important;padding-inline-end:0 !important}"))
        // The coordinator's review of 2026-10-16 (second round): labels and tags own their spacing (§8.4), and the
        // marker and the chevron hang in a gutter on their block's first line box.
        #expect(inLayer("[data-xdict-role=label]{margin-inline-end:0.35em !important}"))
        #expect(inLayer("margin-inline-start:calc(0.25em - (var(--xdict-hit) - 1em) / 2) !important}"),
                "a speaker keeps the control spacing from the word before it")
        #expect(inLayer("[data-xdict-tag]{order:-1 !important;margin-inline:0 0.56em !important}"))
        #expect(inLayer("[data-xdict-before=marker]::before{position:absolute !important;"))
        #expect(inLayer("[data-xdict-control=disclosure]::before{position:absolute !important;"))
        #expect(inLayer("[data-xdict-control=disclosure]{margin-block:0 !important;"
                        + "padding-block:0 !important}"))
        #expect(inLayer(":has(> [data-xdict-control=disclosure]),:has(> :only-child > [data-xdict-control=disclosure])"
                        + "{margin-block:0 !important;padding-block:0 !important}"))
        #expect(inLayer(":has(> [data-xdict-labelled]):not(:has(> :not([data-xdict-labelled],[data-xdict-role=label])))"))
        #expect(inLayer("[data-xdict-labelled]{display:none !important}"))
    }
}

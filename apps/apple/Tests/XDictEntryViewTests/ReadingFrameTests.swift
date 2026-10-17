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

    /// R7a (WI-11, 2026-10-17): the space before a role-marked block is its role's token. A role's token name, from
    /// the core's marks; a section is a phrase block when it holds idioms, phrasal verbs, collocations or derived
    /// words, a heading's otherwise; what no role spaces keeps R7.
    @Test func eachRoleTakesItsOwnSpace() throws {
        let context = try Self.core()
        func space(_ role: String, _ section: String = "", inSense: Bool = false) -> String? {
            context.evaluateScript("XDictFrameCore.spaceOf('\(role)', '\(section)', \(inSense))")?.toString()
        }
        // A section or heading inside a sense is the sense's note (OALD's "synonym proviso", D43): no heading's gap.
        #expect(space("section", "thesaurus", inSense: true) == "")
        #expect(space("section", "idioms", inSense: true) == "")
        #expect(space("heading", inSense: true) == "")
        #expect(space("example", inSense: true) == "example")
        #expect(space("section", "thesaurus") == "heading")
        #expect(space("sense") == "sense")
        #expect(space("sensenum") == "sense")
        #expect(space("example") == "example")
        #expect(space("trans") == "translation")
        #expect(space("example-trans") == "translation")
        #expect(space("subhead") == "subhead")
        #expect(space("heading") == "heading")
        #expect(space("pos") == "pos")
        #expect(space("section", "idioms") == "phrase")
        #expect(space("section", "phrasal") == "phrase")
        #expect(space("section", "etym") == "heading")
        #expect(space("label") == "")
        #expect(space("headword") == "")
        // The margin that makes the collapsed gap the token: a larger margin before it is cancelled by a negative
        // one (margins collapse to the larger positive plus the most negative); a gap too small grows linearly.
        func next(_ margin: Double, _ gap: Double, _ want: Double) -> Double? {
            context.evaluateScript("XDictFrameCore.nextMargin(\(margin), \(gap), \(want))")?.toDouble()
        }
        #expect(next(12, 24, 12) == -12)
        #expect(next(12, 12, 12) == 12)
        #expect(next(12, 8, 12) == 16)
        #expect(next(-12, 16, 12) == -16)
        // Two densities (decided 2026-10-17): B in the main window, A in the lookup panel, in em so they follow the
        // text; chosen by the shell's presentation attribute, never by the pane's width.
        let type = EntryReadingFrame.typeCSS
        #expect(type.contains(":root{--xdict-space-translation:0em;--xdict-space-example:0.5em;--xdict-space-sense:0.75em;"))
        #expect(type.contains(":root[data-xdict-density=panel]{--xdict-space-translation:0em;--xdict-space-example:0.25em;"))
        #expect(!type.contains("@media"))
        let reading = EntryScripts.appearance(.light, frame: .all)
        #expect(reading.contains("roleSpace();"))
        #expect(reading.contains("DENSITY = 'main'"))
        #expect(EntryScripts.appearance(.light, frame: EntryReadingFrame.all.union(.panel)).contains("DENSITY = 'panel'"))
        // Original style has no density: the dictionary's own spacing.
        #expect(EntryReadingFrame.all.union(.panel).applied(originalStyle: true) == .minimal)
    }

    /// R16's classes (WI-11, 2026-10-17): an image is classed by what it is, from its natural size, its place and the
    /// text beside it; no dictionary is named.
    @Test func imagesAreClassedByWhatTheyAre() throws {
        let context = try Self.core()
        func kind(_ facts: String) -> String? { context.evaluateScript("XDictFrameCore.imageClass(\(facts))")?.toString() }
        #expect(kind("{w: 300, h: 300}") == "illustration")
        #expect(kind("{w: 125, h: 59, text: true}") == "inline")
        #expect(kind("{w: 900, h: 600, table: true}") == "table")
        #expect(kind("{w: 474, h: 431, floated: true}") == "float")
        #expect(kind("{w: 64, h: 34, floated: true}") == "badge")
        #expect(kind("{w: 20, h: 20, text: true}") == "icon")
        #expect(kind("{w: 401, h: 51, text: true}") == "text")
        #expect(kind("{w: 61, h: 24, text: true}") == "text")
        #expect(kind("{w: 401, h: 38}") == "text")   // alone on its line too (PEU's intonation)
        #expect(kind("{w: 0, h: 0}") == "")
    }

    /// The pictures a dictionary hides itself (owner, 2026-10-17): kept hidden, gathered under one closed XDict fold,
    /// "Pictures (n)", at the end of the entry. Only an illustration hidden by its own or its picture container's
    /// `display:none`/`visibility:hidden` (a box with no text); never a control, an icon, a missing picture, or a
    /// picture inside a hidden block of text (a dictionary's own closed fold).
    @Test func hiddenPicturesAreGatheredUnderOneFold() throws {
        let context = try Self.core()
        func gathered(_ facts: String) -> Bool { context.evaluateScript("XDictFrameCore.gatherable(\(facts))")?.toBool() == true }
        #expect(gathered("{w: 300, h: 200, hidden: 'image'}"))
        #expect(gathered("{w: 300, h: 200, hidden: 'container'}"))
        #expect(!gathered("{w: 300, h: 200, hidden: 'text'}"))
        #expect(!gathered("{w: 300, h: 200, hidden: ''}"))
        #expect(!gathered("{w: 300, h: 200, hidden: 'image', control: true}"))
        #expect(!gathered("{w: 24, h: 24, hidden: 'image'}"))
        #expect(!gathered("{w: 0, h: 0, hidden: 'image'}"))
        let reading = EntryScripts.appearance(.light, frame: .all)
        #expect(reading.contains("var PICTURES = \"Pictures\";"))
        #expect(reading.contains("pictures();"))
    }

    /// The tokens are the spec's names (`reading-style.md` §1), every one, with a value per theme for the colours.
    @Test func theTokensAreTheSpecsNames() {
        let css = EntryReadingFrame.tokensCSS
        for name in ["base", "font", "font-cjk", "font-phon", "font-mono", "fs-xs", "fs-s", "fs-m", "fs-l", "fs-xl",
                     "fs-xxl", "fs-min", "fs-max", "leading", "leading-tight", "weight-bold", "space-1", "space-5", "gap",
                     "indent", "indent-max", "measure", "pad-block", "pad-inline", "cell-pad", "radius", "hit", "icon",
                     "bg", "panel", "text", "text-2", "rule", "accent", "link", "phon-colour", "plate", "mark", "mark-current",
                     "red-deep", "pink-tint"] {
            #expect(css.contains("--xdict-\(name):"), "\(name)")
        }
        #expect(css.contains("--xdict-measure:none;"))
        #expect(css.contains(":root[data-xdict-theme=light]{--xdict-bg:#ffffff;"))
        #expect(css.contains(":root[data-xdict-theme=dark]{--xdict-bg:#1e1e1e;"))
        #expect(!css.contains("--xdict-base-size"))
    }

    /// SIL's 7.000 fonts renamed "Charis SIL" to "Charis" and "Gentium Plus" to "Gentium": both names are asked for, the
    /// new first, so either installed version sets the transcriptions.
    @Test func thePhoneticFontsAreNamedOldAndNew() {
        #expect(EntryReadingFrame.tokensCSS.contains(
            #"--xdict-font-phon:"XDict Phonetic Serif", "Charis", "Charis SIL", "Doulos SIL", "Gentium", "Gentium Plus", var(--xdict-font);"#))
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

    /// Q7 (ADR-0010): the text face is the reader's choice, a token switch. P18 (owner, 2026-10-17: follow Apple):
    /// New York by default, as Apple's own dictionaries set it; Sans the alternative.
    @Test func theFaceIsATokenSwitch() {
        let css = EntryReadingFrame.tokensCSS
        #expect(css.contains(#"--xdict-font:ui-serif, "New York", var(--xdict-font-cjk), serif;"#))
        #expect(css.contains(#"--xdict-font-cjk:"Songti SC", "STSong";"#))
        #expect(css.contains(#":root[data-xdict-face=sans]{--xdict-font:-apple-system, "Helvetica Neue", var(--xdict-font-cjk), sans-serif;"#))
        #expect(EntryScripts.appearance(.light, frame: [.column, .type, .sans]).contains("FACE = 'sans'"))
        #expect(EntryScripts.appearance(.light, frame: .all).contains("FACE = 'serif'"))
        #expect(!EntryReadingFrame.all.contains(.sans))
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
        #expect(!EntryPane.restyles(from: .all, to: [.column, .type, .sans]))
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
        #expect(css.contains("[data-xdict-tag]{font-family:var(--xdict-font-text);font-style:normal;font-size:var(--xdict-fs-xs);"))
        // A tag ends its control with 0.35em of the text before the next control or word (0.56em of the tag's own
        // 0.625em): MED's `UK` touched the next speaker (icon sweep 2026-10-15, §8.4).
        #expect(css.contains("margin-inline-end:0.56em"))
        #expect(!css.contains("url(http"))
        #expect(EntryScripts.appearance(.light, frame: .all).contains("[data-xdict-icon=speaker]"))
        #expect(!EntryScripts.appearance(.light, frame: []).contains("[data-xdict-icon=speaker]"))
    }

    /// Unification R (2026-10-16): the transcription face reaches every descendant but a speaker's tag, face only; the
    /// lead resets size and face inside it, never weight or colour; links are the link colour; the browser's own
    /// heading sizes and block margins are on the scale and the space tokens.
    /// A long word breaks only where it would overflow: `anywhere` counted toward a table column's min-content, so
    /// CALD's level table drew one letter a line.
    @Test func wordsBreakOnlyToAvoidOverflow() {
        #expect(EntryReadingFrame.columnCSS.contains("overflow-wrap:break-word !important"))
        #expect(!EntryReadingFrame.columnCSS.contains("anywhere"))
        #expect(!EntryReadingFrame.minimalCSS.contains("anywhere"))
    }

    /// R caps a dictionary's inline horizontal spacing in the reading style; original style keeps the dictionary's.
    @Test func inlineSpacingIsCappedInTheReadingStyleOnly() {
        let reading = EntryScripts.appearance(.light, frame: .all)
        let original = EntryScripts.appearance(.light, frame: EntryReadingFrame.all.applied(originalStyle: true))
        #expect(reading.contains("var SPACE_CAP = 0.25,"))
        #expect(original.contains("var SPACE_CAP = 0,"))
        // The browser's list bullets become XDict's marker the same way (reading style only, gated by the same flag),
        // and a marked item draws no list marker of its own.
        #expect(reading.contains("li.setAttribute('data-xdict-before', 'marker')"))
        #expect(EntryReadingFrame.marksCSS.contains("list-style:none !important"))
    }

    /// A bullet the dictionary wrote as text, alone in its block (NOAD's "harm": `<div class="m1"><div class="opt">•
    /// </div></div>`), is not drawn in the reading style: the frame marks the block, the marks layer hides it. Only a
    /// block whose whole shown text is bullet glyphs.
    @Test func aLoneTextBulletIsHiddenInTheReadingStyle() throws {
        let reading = EntryScripts.appearance(.light, frame: .all)
        #expect(reading.contains("function start() { install(); name(document); bullets(); loneBullets(); spacing(); lists(); pictures(); images(); roleSpace(); }"))
        // G14 (owner, 2026-10-17): frame.js reads which list levels show a marker; the flush ones start flush.
        #expect(reading.contains("all[i].setAttribute('data-xdict-list', v)"))
        #expect(reading.contains("if (!SPACE_CAP || !document.body || document.readyState !== 'complete') return;\n    var all"))
        #expect(EntryReadingFrame.marksCSS.contains("[data-xdict-lone-bullet]{display:none !important}"))
        let start = try #require(reading.range(of: "var GLYPHS = "))
        let end = try #require(reading.range(of: ";\n", range: start.upperBound..<reading.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript(String(reading[start.lowerBound..<end.upperBound]))
        func lone(_ text: String) -> Bool {
            context.setObject(text, forKeyedSubscript: "t" as NSString)
            return context.evaluateScript("GLYPHS.test(t.replace(/\\s+/g, ''))")?.toBool() == true
        }
        #expect(lone("•"))
        #expect(lone(" ■ \n"))
        #expect(!lone("• come to no harm"))
        #expect(!lone(""))
        #expect(!lone("·"))   // a syllable dot is the word's
    }

    @Test func unificationRsRulesAreInTheTypeLayer() {
        let css = EntryReadingFrame.typeCSS
        #expect(css.contains("@layer xdict-unify{"))
        #expect(css.contains(":not([data-xdict-tag],[data-xdict-icon]){font-family:var(--xdict-font-phon) !important}"))
        // P20 (follow Apple): a transcription is in the secondary label colour, its speaker the link colour.
        #expect(css.contains("{color:var(--xdict-phon-colour) !important}"))
        // A label's inside takes the label's size, face and colour.
        #expect(css.contains("{font-size:inherit !important;font-family:inherit !important;color:inherit !important;"
            + "line-height:inherit !important}"))
        #expect(!css.contains("[data-xdict-lead] :not([data-xdict-phon],[data-xdict-phon] *,[data-xdict-role=label],"
            + "[data-xdict-role=label] *,[data-xdict-tag],[data-xdict-icon]){font-weight"))
        #expect(css.contains("color:var(--xdict-link) !important"))
        #expect(css.contains("line-height:inherit !important;color:inherit !important}"), "NOAD's coloured headword span")
        #expect(css.contains("[data-xdict-lead][data-xdict-lead] a:any-link"), "MWU's headword link")
        #expect(css.contains(":where(h1){font-size:var(--xdict-fs-xxl);"))
        #expect(css.contains("{margin-block:var(--xdict-space-4)}"))
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
        #expect(texts.count == 20)   // text, text-2, the link, the accent, and 8 hues × plain and deep
        for text in texts {
            for surface in surfaces {
                let (tl, td) = try #require(table[text]), (sl, sd) = try #require(table[surface])
                let (light, dark) = (try contrast(tl, sl), try contrast(td, sd))
                #expect(light >= 4.5, "light \(text) on \(surface): \(light)")
                #expect(dark >= 4.5, "dark \(text) on \(surface): \(dark)")
            }
        }
        // Each accent the reader can choose holds the 7:1 its doc comment states, on both surfaces, in both themes.
        for accent in EntryReadingFrame.Accent.allCases {
            for surface in surfaces {
                let (sl, sd) = try #require(table[surface])
                let (light, dark) = (try contrast(accent.values.light, sl), try contrast(accent.values.dark, sd))
                #expect(light >= 7, "light \(accent) on \(surface): \(light)")
                #expect(dark >= 7, "dark \(accent) on \(surface): \(dark)")
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
        // The `content` property only, not one ending in it (`justify-content:`).
        let contents = css.ranges(of: /[;{\n]content:([^;}]*)/).map { String(css[$0].drop(while: { $0 != ":" }).dropFirst()) }
        #expect(!contents.isEmpty)
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

    /// A speaker and the transcription it plays stay on one line (CALD "remember sb to sb" broke between them): the
    /// run from a speaker through blanks and other speakers to the next transcription is held together; anything else
    /// in between (a word) ends it, and a transcription first or alone is left as it is.
    @Test func aSpeakerRunsOnToItsTranscription() throws {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
        context.evaluateScript(EntryScripts.pronRunCore)
        // Nodes: 's' a speaker, 'p' a transcription, ' ' a blank text, 'w' a word or other element.
        context.evaluateScript("""
            function chain(kinds) {
              var nodes = kinds.split('').map(function (k, i) { return { kind: k, i: i, nextSibling: null }; });
              for (var i = 0; i + 1 < nodes.length; i++) nodes[i].nextSibling = nodes[i + 1];
              return nodes;
            }
            var is = { speaker: function (n) { return n.kind === 's'; }, phon: function (n) { return n.kind === 'p'; },
                       blank: function (n) { return n.kind === ' '; } };
            function run(kinds) {
              var r = XDictPronRunCore.run(chain(kinds)[0], is);
              return r ? r.first.i + '-' + r.last.i : 'none';
            }
            """)
        func run(_ kinds: String) -> String? { context.evaluateScript("run('\(kinds)')")?.toString() }
        #expect(run("s s p") == "0-4", "two speakers and their transcription")
        #expect(run("sp") == "0-1")
        #expect(run("s w p") == "none", "a word between: not its transcription")
        #expect(run("s") == "none")
        #expect(run("s  ") == "none")
        #expect(EntryReadingFrame.marksCSS.contains("[data-xdict-pron-run]{white-space:nowrap !important}"))
        // A transcription with its speakers after it (PEU's `/ˈraɪdə(r)/<div data-xdict-speakers>`), 'b' a speakers box:
        // the run is the transcription through the last speaker or box; a word between ends it.
        context.evaluateScript("""
            is.speakers = function (n) { return n.kind === 'b'; };
            function after(kinds) {
              var r = XDictPronRunCore.after(chain(kinds)[0], is);
              return r ? r.first.i + '-' + r.last.i : 'none';
            }
            """)
        func after(_ kinds: String) -> String? { context.evaluateScript("after('\(kinds)')")?.toString() }
        #expect(after("pb") == "0-1")
        #expect(after("p s s") == "0-4", "a transcription and the two speakers after it")
        #expect(after("p w s") == "none", "a word between: not its speakers")
        #expect(after("p") == "none")
        #expect(EntryScripts.installed(.light, frame: .minimal).contains(EntryScripts.pronRunDOM))
        #expect(EntryScripts.installed(.light, frame: .all).contains(EntryScripts.pronRunDOM))
    }

    // MARK: - Apple's Dictionary, group D (`dev-docs/apple-dictionary-parity.md` P17–P28; owner, 2026-10-17: follow Apple)

    /// P17: no measure: the text runs the pane's width, left-aligned, 16 pt (1rem at the default size) from its edges.
    @Test func p17TheColumnRunsThePaneAtApplesInsets() {
        let css = EntryReadingFrame.columnCSS
        #expect(css.contains("body{margin:0 !important;padding:var(--xdict-pad-block) var(--xdict-pad-inline) !important;"
            + "max-width:none !important;"))
        #expect(!css.contains("var(--xdict-measure)"))
        #expect(EntryReadingFrame.tokensCSS.contains("--xdict-pad-inline:1rem;"))
    }

    /// P18: New York at line height 1.4, Apple's dictionaries' `line-height: 140%`.
    @Test func p18NewYorkAtLeading14() {
        let css = EntryReadingFrame.tokensCSS
        #expect(css.contains("--xdict-leading:1.4;"))
        #expect(css.contains(#"--xdict-font:ui-serif, "New York""#))
        #expect(css.contains(#"--xdict-font-phon:"XDict Phonetic Serif""#))
    }

    /// P19: the headword at weight 500 and Apple's size (22.7 px rendered at the default 16: 23 px, 1.4375rem).
    @Test func p19TheHeadwordIsWeight500AtApplesSize() {
        let tokens = EntryReadingFrame.tokensCSS, css = EntryReadingFrame.typeCSS
        #expect(tokens.contains("--xdict-fs-hw:1.4375rem;"))
        #expect(tokens.contains("--xdict-weight-headword:500;"))
        #expect(css.contains("[data-xdict-lead]{font-size:var(--xdict-fs-hw) !important;"))
        #expect(css.contains("font-family:var(--xdict-font) !important;font-weight:var(--xdict-weight-headword) !important;"))
    }

    /// P20–P23: the pronunciation, the part of speech, sense numbers and examples in the secondary label colour; the part
    /// of speech upright in the system face at 500, sense numbers in it at 600.
    @Test func p20to23SecondaryRolesFollowApple() {
        let tokens = EntryReadingFrame.tokensCSS, css = EntryReadingFrame.typeCSS
        #expect(tokens.contains("--xdict-phon-colour:var(--xdict-text-2);"))
        #expect(tokens.contains(#"--xdict-font-ui:-apple-system, system-ui, "Helvetica Neue", "PingFang SC", sans-serif;"#))
        #expect(css.contains("{font-family:var(--xdict-font-ui) !important;font-style:normal !important;"
            + "font-synthesis-style:none !important;font-weight:500 !important;"))
        #expect(css.contains("color:var(--xdict-text-2) !important;background:none !important}"))
        #expect(css.contains("{font-family:var(--xdict-font-ui) !important;font-weight:var(--xdict-weight-bold) !important;"
            + "font-style:normal !important;color:var(--xdict-text-2) !important;background:none !important}"))
        #expect(css.contains("[data-xdict-sure=example][data-xdict-sure]{color:var(--xdict-text-2) !important}"))
        #expect(!css.contains("var(--xdict-accent)"), "no role of Apple's is drawn in the accent")
    }

    /// P24: a section heading is Apple's label: small capitals of the lowercase, 0.03em apart, secondary colour.
    @Test func p24SectionHeadingsAreApplesLabels() {
        let css = EntryReadingFrame.typeCSS
        #expect(css.contains("font-size:var(--xdict-fs-m) !important;line-height:var(--xdict-leading) !important;"
            + "font-weight:normal !important;font-style:normal !important;font-variant-caps:small-caps !important;"
            + "text-transform:lowercase !important;letter-spacing:0.03em !important;color:var(--xdict-text-2) !important}"))
    }

    /// P26, P27: the system's colours. Light: label black, secondary label darkened from 50% black (#808080, 3.95:1)
    /// to the lightest grey that reads 4.5:1 on every surface and tint (#6d6d6d), linkColor, quaternary label for rules.
    /// Dark: white, 54.9% white on #1e1e1e (#9a9a9a), the dark linkColor, 9.8% white.
    @Test func p26p27SystemColours() {
        let table = Dictionary(uniqueKeysWithValues: EntryReadingFrame.colours.map { ($0.0, [$0.1, $0.2]) })
        #expect(table["bg"] == ["#ffffff", "#1e1e1e"])
        #expect(table["text"] == ["#000000", "#ffffff"])
        #expect(table["text-2"] == ["#6d6d6d", "#9a9a9a"])
        #expect(table["link"] == ["#0068da", "#419cff"])
        #expect(table["rule"] == ["#e6e6e6", "#343434"])
    }

    /// P28: links carry no underline but on hover; in the lookup panel they are drawn as plain text.
    @Test func p28LinksUnderlineOnHoverAndArePlainInThePanel() {
        let css = EntryReadingFrame.typeCSS
        #expect(css.contains("a:any-link:not([data-xdict-control]){text-decoration:none !important}"))
        #expect(css.contains("a:any-link:not([data-xdict-control]):hover{text-decoration:underline !important}"))
        #expect(css.contains(":root[data-xdict-density=panel] a:any-link:not([data-xdict-control]),"
            + ":root[data-xdict-density=panel] a:any-link:not([data-xdict-control]) :not([data-xdict-role=label],"
            + "[data-xdict-role=label] *){color:var(--xdict-text) !important}"))
    }
}

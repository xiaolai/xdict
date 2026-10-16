import Foundation

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

    /// The text face the reader chose (ADR-0010 Q7): Serif (New York, Songti SC) instead of the default Sans. A token
    /// switch on the root, not a layer: it changes `--xdict-font`, nothing else.
    public static let serif = EntryReadingFrame(rawValue: 1 << 2)

    public static let all: EntryReadingFrame = [.column, .type]

    /// "Original style"'s whole frame (ADR-0010 Q3, `reading-style.md` §6): the page's insets, containment, and a light
    /// paper under the dictionary. Never with the other layers.
    public static let minimal = EntryReadingFrame(rawValue: 1 << 3)

    /// The paper an entry in its own style is drawn on in dark: the dictionary's colours assume a white page, so a
    /// light one, a little dimmer than white.
    static let paper = "#ecebe6"

    /// The page's insets (the reading style's own padding values, written out: original style loads no tokens but the
    /// palette), `contain: layout` (R13: nothing pins itself over the pane), and the paper: white in light, `paper` in
    /// dark, with dark text where the dictionary sets none. The dictionary's own margins and colours stay its own.
    /// XDict's marks draw with the palette; on the paper they take its light values in dark too.
    static let minimalCSS = "html{padding:1.25rem clamp(0.75rem, 4vw, 2rem) !important;color-scheme:light only;"
        + "color:#1d1d1f;box-sizing:border-box}"
        + ":root[data-xdict-theme=light]{background:#ffffff !important}"
        + ":root[data-xdict-theme=dark]{background:\(paper) !important}"
        + ":root[data-xdict-theme=dark]{\(colours.map { "--xdict-\($0.0):\($0.1);" }.joined())}"
        + "body{contain:layout !important;overflow-wrap:anywhere}"


    /// In original style transcriptions draw in the bundled phonetic faces too (a dictionary's own IPA font is often
    /// missing); their colour stays the dictionary's.
    /// `!important`, and on the transcription's own elements: a dictionary's font rule on its class (MWU's) outranks
    /// a plain one. XDict's controls and labels inside keep their own face.
    static let originalPhonCSS = "[data-xdict-phon],"
        + "[data-xdict-phon] :not([data-xdict-control],[data-xdict-control] *,[data-xdict-role=label])"
        + "{--xdict-font:var(--xdict-font-phon);font-family:var(--xdict-font-phon) !important}"

    /// What a dictionary is shown with: nothing of the frame when the reader chose its "Original style" (ADR-0010 Q3).
    public func applied(originalStyle: Bool) -> EntryReadingFrame { originalStyle ? .minimal : self }

    /// **The tokens (§1), in one place.** Names are fixed by the spec; values are the gallery's to tune. Colours per
    /// theme on `:root[data-xdict-theme=…]`, which the appearance script sets.
    static let tokens: [(String, String)] = [
        ("base", "16px"),
        ("font-cjk", #""PingFang SC", "Hiragino Sans GB""#),
        ("font", #"-apple-system, "Helvetica Neue", var(--xdict-font-cjk), sans-serif"#),
        // XDict's own face first (`EntryFonts`: Noto Sans; Charis in Serif, below), then what the Mac may have.
        ("font-phon", #""\#(EntryFonts.sans)", \#(phonFallbacks)"#),
        // The text face, kept where `--xdict-font` means the phonetic face (inside a transcription, `typeCSS`).
        ("font-text", "var(--xdict-font)"),
        ("font-mono", #"ui-monospace, "SF Mono", Menlo, monospace"#),
        ("fs-xs", "0.75rem"), ("fs-s", "0.875rem"), ("fs-m", "1rem"), ("fs-l", "1.125rem"), ("fs-xl", "1.25rem"),
        ("fs-xxl", "1.5rem"), ("fs-min", "var(--xdict-fs-xs)"), ("fs-max", "var(--xdict-fs-xxl)"),
        ("leading", "1.6"), ("leading-tight", "1.3"), ("weight-bold", "600"),
        ("space-1", "0.25rem"), ("space-2", "0.5rem"), ("space-3", "0.75rem"), ("space-4", "1rem"), ("space-5", "1.5rem"),
        ("gap", "var(--xdict-space-2)"), ("indent", "1.5em"), ("indent-max", "calc(3 * var(--xdict-indent))"),
        ("measure", "36em"), ("pad-block", "1.25rem"), ("pad-inline", "clamp(0.75rem, 4vw, 2rem)"),
        ("cell-pad", "0.25em 0.75em"), ("radius", "6px"), ("hit", "24px"), ("icon", "1em"),
        ("link", "var(--xdict-blue)"), ("phon-colour", "var(--xdict-text)"),
        ("mark", "#ffe36e"), ("mark-current", "#ff9632"),
    ]

    /// SIL 7.000 renamed Charis SIL and Gentium Plus; the new names first, the old for an earlier install.
    static let phonFallbacks = #""Charis", "Charis SIL", "Doulos SIL", "Gentium", "Gentium Plus", var(--xdict-font)"#

    /// §1.3: surfaces, text, and eight hue families × deep / plain / tint, light then dark.
    static let colours: [(String, String, String)] = [
        ("bg", "#ffffff", "#1e1e1e"), ("panel", "#f3f3f5", "#2a2a2c"), ("text", "#1d1d1f", "#e6e6e9"),
        ("text-2", "#636366", "#a3a3a8"), ("rule", "#d8d8dc", "#3a3a3d"), ("plate", "transparent", "#ececef"),
        ("red-deep", "#901114", "#fec9c2"), ("red", "#af342f", "#fb988d"), ("red-tint", "#ffebe8", "#3e2724"),
        ("orange-deep", "#773a00", "#ffcba9"), ("orange", "#9b4e01", "#f2a26a"), ("orange-tint", "#ffece0", "#3c291d"),
        ("yellow-deep", "#5c4c00", "#ecd78a"), ("yellow", "#796502", "#cfb656"), ("yellow-tint", "#f6f0da", "#332e19"),
        ("green-deep", "#035e23", "#aaeab2"), ("green", "#047b30", "#80cd8b"), ("green-tint", "#e3f6e5", "#223324"),
        ("teal-deep", "#055959", "#81ecec"), ("teal", "#057575", "#3bcfcf"), ("teal-tint", "#daf7f6", "#163333"),
        ("blue-deep", "#02489f", "#c0d9fe"), ("blue", "#2063bf", "#8ab9ff"), ("blue-tint", "#e8f1fe", "#232e3f"),
        ("purple-deep", "#622c91", "#e2ccfe"), ("purple", "#7c48ae", "#c9a3f5"), ("purple-tint", "#f4ecff", "#32293c"),
        ("pink-deep", "#881356", "#fec5dc"), ("pink", "#a63470", "#f297bf"), ("pink-tint", "#feeaf2", "#3c2730"),
    ]

    /// The palette alone, per theme: what the core's colour tokens need even with no frame ("Original style").
    static var paletteCSS: String {
        func block(_ pairs: [(String, String)]) -> String { pairs.map { "--xdict-\($0.0):\($0.1);" }.joined() }
        return ":root[data-xdict-theme=light]{\(block(colours.map { ($0.0, $0.1) }))}"
            + ":root[data-xdict-theme=dark]{\(block(colours.map { ($0.0, $0.2) }))}"
    }

    static var tokensCSS: String {
        func block(_ pairs: [(String, String)]) -> String { pairs.map { "--xdict-\($0.0):\($0.1);" }.joined() }
        return EntryFonts.fontFaceCSS + ":root{\(block(tokens))}" + paletteCSS
            + #":root[data-xdict-face=serif]{--xdict-font:ui-serif, "New York", var(--xdict-font-cjk), serif;"#
            + #"--xdict-font-cjk:"Songti SC", "STSong";--xdict-font-phon:"\#(EntryFonts.serif)", \#(phonFallbacks)}"#
            + ":lang(zh-Hant){--xdict-font-cjk:\"PingFang TC\"}:lang(ja){--xdict-font-cjk:\"Hiragino Sans\"}"
            + ":lang(ko){--xdict-font-cjk:\"Apple SD Gothic Neo\"}"
    }

    /// R1, R10, R13, R16. The page's properties win by `!important` (the core drops the dictionary's page rules); the
    /// column is the measure plus the inline padding. The quirks-mode table reset is undone, so a table's text is the
    /// scale's. Data tables scroll in the core's wrapper; only an unwrapped one scrolls itself. `contain: layout` makes
    /// the body the containing block of a dictionary's `position: fixed`, so nothing pins itself over the pane.
    static let columnCSS = "html{padding:0 !important;font-size:var(--xdict-base) !important;"
        + "background:var(--xdict-bg) !important;color:var(--xdict-text) !important;display:block !important;"
        + "visibility:visible !important;opacity:1 !important;filter:none !important;transform:none !important;"
        + "zoom:1 !important;position:static !important;writing-mode:horizontal-tb !important}"
        + "body{margin:0 auto !important;padding:var(--xdict-pad-block) var(--xdict-pad-inline) !important;"
        + "max-width:calc(var(--xdict-measure) + 2 * var(--xdict-pad-inline)) !important;width:auto !important;"
        + "min-width:0 !important;box-sizing:border-box !important;overflow-wrap:anywhere !important;"
        + "contain:layout !important;display:block !important;visibility:visible !important;opacity:1 !important;"
        + "filter:none !important;transform:none !important;zoom:1 !important;position:static !important;"
        + "float:none !important;writing-mode:horizontal-tb !important}"
        + "table{font:inherit;line-height:inherit;color:inherit;white-space:inherit;text-align:inherit;"
        + "border-collapse:collapse}"
        + "[data-xdict-scroll]{overflow-x:auto;max-width:100%;margin-block:var(--xdict-gap)}"
        + "[data-xdict-table=data] td,[data-xdict-table=data] th{padding:var(--xdict-cell-pad);vertical-align:top;"
        + "text-align:start}"
        // No fills anywhere (owner, 2026-10-15): the header row is told by weight and the space under it.
        + "[data-xdict-table=data] th,[data-xdict-table=data] thead td{font-weight:var(--xdict-weight-bold);"
        + "padding-bottom:var(--xdict-space-2)}"
        + "[data-xdict-table=layout]{border-spacing:0}[data-xdict-table=layout] td{padding:0 0.25em 0 0}"
        + ":not([data-xdict-scroll])>table[data-xdict-table=data]{display:block;overflow-x:auto;max-width:100%}"
        + "img{max-width:100%;height:auto}"
        // A plain link the dictionary leaves uncoloured gets XDict's link colour, not WebKit's default (#0000EE,
        // #9E9EFF in dark); zero specificity, so a colour the core mapped from the dictionary still wins.
        + ":where(a:any-link){color:var(--xdict-link)}"

    /// XDict's speaker (§5.5): its own drawing, a speaker with two waves, as an inline SVG mask filled with the text's
    /// colour, so it follows the theme, the link colour and hover. No URL but `data:`, which the policy already allows.
    static let speakerSVG = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'>"
        + "<path d='M1.5 5.5h3l4-3.2v11.4l-4-3.2h-3z'/>"
        + "<path d='M10.6 5.2a3.6 3.6 0 0 1 0 5.6' fill='none' stroke='black' stroke-width='1.5' stroke-linecap='round'/>"
        + "<path d='M12.4 3a6.6 6.6 0 0 1 0 10' fill='none' stroke='black' stroke-width='1.5' stroke-linecap='round'/>"
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
    static func controlsCSS(ukTag: String = "UK", usTag: String = "US") -> String {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "") + "\"" }
        return "[data-xdict-control-mode=replace]>:not([data-xdict-icon]):not([data-xdict-tag]){display:none !important}"
            + "[data-xdict-control-mode=prefix]>img,[data-xdict-control-mode=prefix]>:empty:not([data-xdict-icon]):not([data-xdict-tag]){display:none !important}"
            + "[data-xdict-control]::before,[data-xdict-control]::after{content:none !important}"
            + "[data-xdict-control]{background-image:none !important;cursor:pointer}"
            // A fold head is often a block (a heading, a box's title): it keeps its own layout and colour.
            + "[data-xdict-control]:not([data-xdict-control=disclosure]){color:var(--xdict-link);text-decoration:none;"
            + "display:inline-flex;align-items:baseline;gap:0.15em;"
            + "padding:calc((var(--xdict-hit) - 1em) / 2);margin:calc((var(--xdict-hit) - 1em) / -2);"
            + "border-radius:var(--xdict-radius)}"
            + "[data-xdict-control]:focus-visible{outline:2px solid var(--xdict-link);outline-offset:0}"
            + "[data-xdict-icon=speaker]{display:inline-block;width:var(--xdict-icon);height:var(--xdict-icon);"
            + "vertical-align:-0.15em;background-color:currentColor;-webkit-mask:\(speakerMask) center/contain no-repeat;"
            + "mask-image:\(speakerMask);mask-size:contain;mask-repeat:no-repeat;mask-position:center}"
            + "[data-xdict-unavailable]{opacity:0.4;cursor:default}"
            // In XDict's face even inside a transcription (OALECD's sound links wrap them).
            + "[data-xdict-tag]{font-family:var(--xdict-font-text);font-style:normal;font-size:0.625em;font-variant-caps:all-small-caps;color:var(--xdict-text-2);"
            // 0.35em of the text after the tag (0.56em of its own 0.625em): the next speaker or word does not touch it.
            + "letter-spacing:0.02em;margin-inline-end:0.56em}"
            + "[data-xdict-accent=uk]>[data-xdict-tag]::before{content:\(quoted(ukTag))}"
            + "[data-xdict-accent=us]>[data-xdict-tag]::before{content:\(quoted(usTag))}"
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
    /// too; no cycle, as `--xdict-font-phon` is declared on the root alone and arrives here resolved.
    static let typeCSS = "body{font:400 var(--xdict-fs-m)/var(--xdict-leading) var(--xdict-font) !important}"
        + "[data-xdict-phon]{--xdict-font:var(--xdict-font-phon);font-family:var(--xdict-font-phon);"
        + "color:var(--xdict-phon-colour)}"
}

extension EntryScripts {
    /// The gallery's arithmetic, with no DOM: the entry's dominant text size, the size most of its characters are set
    /// in. A measurement only; nothing on the page is scaled by it.
    static let frameCore = #"""
        var XDictFrameCore = (function () {
          'use strict';
          function dominant(samples) {
            var weight = {};
            samples.forEach(function (s) {
              if (!(s[0] > 0) || !(s[1] > 0)) return;
              var b = Math.round(s[0] * 2) / 2;
              weight[b] = (weight[b] || 0) + s[1];
            });
            var best = NaN, most = 0;
            Object.keys(weight).forEach(function (k) {
              if (weight[k] > most) { most = weight[k]; best = parseFloat(k); }
            });
            return best;
          }
          function opaque(css) {
            var m = /rgba?\(([^)]*)\)/.exec(String(css));
            if (!m) return false;
            var p = m[1].split(/[\s,\/]+/).filter(function (x) { return x.length; });
            return p.length < 4 || parseFloat(p[3]) > 0.05;
          }
          return { dominant: dominant, opaque: opaque };
        })();
        """#

    /// The frame on the page, in the shell's world: the theme attribute, the tokens and the layers' stylesheets, put
    /// back if a page script removes or rewrites them. `__xdictFrame.measure()` reports what the gallery compares.
    static func frameDOM(_ frame: EntryReadingFrame, scheme: EntryColourScheme,
                         labels: EntryReadingFrame.SpeakerLabels) -> String {
        let column = frame.contains(.column)
            ? EntryReadingFrame.columnCSS + EntryReadingFrame.controlsCSS(ukTag: labels.ukTag, usTag: labels.usTag)
                + EntryReadingFrame.marksCSS + EntryReadingFrame.readingLabelsCSS : ""
        let names = ["uk": labels.uk, "us": labels.us, "other": labels.other]
        let tokenNames = (EntryReadingFrame.colours.map(\.0) + ["link", "phon-colour"]).map { "\"\($0)\"" }.joined(separator: ",")
        let namesJSON = (try? JSONSerialization.data(withJSONObject: !frame.isDisjoint(with: [.column, .minimal]) ? names : [:], options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let type = frame.contains(.type) ? EntryReadingFrame.typeCSS : ""
        // "Original style": the minimal frame and XDict's whole marks layer (the owner, 2026-10-16), no column or type.
        let minimal = frame.contains(.minimal)
            ? EntryReadingFrame.minimalCSS + EntryReadingFrame.controlsCSS(ukTag: labels.ukTag, usTag: labels.usTag)
                + EntryReadingFrame.marksCSS + EntryReadingFrame.originalPhonCSS : ""
        let tokens = frame.subtracting(.serif).isEmpty ? EntryReadingFrame.paletteCSS : EntryReadingFrame.tokensCSS
        let face = frame.contains(.serif) ? "serif" : "sans"
        return """
            (function () {
              'use strict';
              var THEME = '\(scheme.rawValue)', FACE = '\(face)', SHEETS = [['xdict-frame-tokens', \(jsString(tokens))],
                ['xdict-frame-column', \(jsString(column))], ['xdict-frame-type', \(jsString(type))],
                ['xdict-frame-minimal', \(jsString(minimal))]];
              var ID = /^xdict-frame-/;
              function sheet(id, text) {
                var s = document.getElementById(id);
                if (!s) { s = document.createElement('style'); s.id = id; }
                if (s.textContent !== text) s.textContent = text;
                // Last in the head. Only another node of the entry's after it moves it: the frame's own sheets
                // following each other is the settled state, so two of them never chase each other to the end.
                var parent = document.head || document.documentElement;
                var after = s.parentNode === parent ? s.nextSibling : parent.firstChild;
                while (after && ID.test(after.id || '')) after = after.nextSibling;
                if (s.parentNode !== parent || after !== null) parent.appendChild(s);
              }
              function install() {
                if (!SHEETS.some(function (s) { return s[1]; })) return;
                var root = document.documentElement;
                if (root.getAttribute('data-xdict-theme') !== THEME) root.setAttribute('data-xdict-theme', THEME);
                if (root.getAttribute('data-xdict-face') !== FACE) root.setAttribute('data-xdict-face', FACE);
                SHEETS.forEach(function (s) { if (s[1]) sheet(s[0], s[1]); });
              }
              // §5.2: each speaker the core marked is a button with a name, set here in the shell's world.
              var NAMES = \(namesJSON);
              function name(root) {
                if (!NAMES.other || !root || !root.querySelectorAll) return;
                root.querySelectorAll('[data-xdict-control=speaker]').forEach(function (a) {
                  var label = NAMES[a.getAttribute('data-xdict-accent')] || NAMES.other;
                  if (a.getAttribute('aria-label') !== label) a.setAttribute('aria-label', label);
                  if (a.getAttribute('role') !== 'button') a.setAttribute('role', 'button');
                });
              }
              // The palette's values in this theme, as computed colours, for the gallery's check that every text colour
              // on the page is one of them.
              var TOKENS = [\(tokenNames)];
              function palette() {
                var probe = document.createElement('span'), out = {};
                (document.body || document.documentElement).appendChild(probe);
                TOKENS.forEach(function (t) { probe.style.color = 'var(--xdict-' + t + ')'; out[getComputedStyle(probe).color] = t; });
                probe.remove();
                return out;
              }
              function measure() {
                var colours = {}, families = {}, prose = 0, proseFramed = 0, below = 0, lowest = null, root = document.documentElement;
                var samples = [], leading = [], left = Infinity, right = -Infinity, chars = 0, framed = 0;
                var walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
                for (var n = walker.nextNode(); n; n = walker.nextNode()) {
                  var t = n.nodeValue.replace(/\\s+/g, '');
                  if (!t.length || !n.parentElement) continue;
                  var r = document.createRange(); r.selectNodeContents(n);
                  var rects = r.getClientRects();
                  if (!rects.length) continue;
                  var pcs = getComputedStyle(n.parentElement);
                  samples.push([parseFloat(pcs.fontSize), t.length]);
                  var lh = pcs.lineHeight === 'normal' ? 1.2 : parseFloat(pcs.lineHeight) / parseFloat(pcs.fontSize);
                  leading.push([Math.round(lh * 20) / 20, t.length]);
                  chars += t.length;
                  if (/^-apple-system/.test(pcs.fontFamily)) framed += t.length;
                  if (!n.parentElement.closest('[data-xdict-phon]')) {
                    prose += t.length;
                    if (/^-apple-system|^ui-serif/.test(pcs.fontFamily)) proseFramed += t.length;
                  }
                  families[pcs.fontFamily] = (families[pcs.fontFamily] || 0) + t.length;
                  // Computed contrast, not pixels: the text's colour against the first opaque background behind it.
                  var fg = XDictReadability.parse(pcs.color), bg = null;
                  for (var e = n.parentElement; e && !bg; e = e.parentElement) {
                    var c = XDictReadability.parse(getComputedStyle(e).backgroundColor);
                    if (c && c[3] >= 0.5) bg = c;
                  }
                  if (!bg) bg = XDictReadability.parse(getComputedStyle(root).backgroundColor) || [255, 255, 255, 1];
                  if (bg[3] < 0.5) bg = [255, 255, 255, 1];
                  colours[pcs.color] = colours[pcs.color] || { chars: 0, sample: n.nodeValue.trim().slice(0, 30) + ' <'
                    + n.parentElement.tagName.toLowerCase() + (n.parentElement.className ? '.' + String(n.parentElement.className) : '') + '>' };
                  colours[pcs.color].chars += t.length;
                  if (fg) {
                    var ratio = XDictReadability.contrast(fg, bg);
                    if (ratio < 4.5) below += t.length;
                    if (!lowest || ratio < lowest.ratio) {
                      lowest = { ratio: Math.round(ratio * 100) / 100, colour: pcs.color, background: 'rgb(' + bg.slice(0, 3).join(', ') + ')',
                                 text: n.nodeValue.trim().slice(0, 40) };
                    }
                  }
                  for (var i = 0; i < rects.length; i++) {
                    if (rects[i].width < 1) continue;
                    left = Math.min(left, rects[i].left); right = Math.max(right, rects[i].right);
                  }
                }
                var size = XDictFrameCore.dominant(samples);
                var body = document.body;
                // R13's containment, observed: a fixed probe at `right:0` ends at the body's padding box when the body
                // contains it, at the viewport's right edge otherwise; undecided (null) where the two coincide, as in a
                // window no wider than the column. (`top:0` cannot tell: the body starts at the viewport's top; nor can
                // `bottom:0`: a dictionary's `body{height:100%}` ends it at the viewport's bottom.)
                var contained = null;
                if (body) {
                  var probe = document.createElement('div');
                  probe.style.cssText = 'position:fixed;right:0;top:0;width:1px;height:1px';
                  body.appendChild(probe);
                  var bs = getComputedStyle(body), box = body.getBoundingClientRect();
                  var inner = box.right - parseFloat(bs.borderRightWidth || '0'), view = root.clientWidth;
                  var at = probe.getBoundingClientRect().right;
                  probe.remove();
                  if (Math.abs(inner - view) >= 1) contained = Math.abs(at - inner) < 1;
                }
                // What "Plain by default" leaves: elements with a background or a border, and images on the page.
                var boxes = 0, kinds = {}, all = body ? body.getElementsByTagName('*') : [];
                for (var j = 0; j < all.length && j < 8000; j++) {
                  if (all[j].hasAttribute('data-xdict-icon')) continue;   // the frame's own glyph, drawn as a mask
                  var es = getComputedStyle(all[j]), what = '';
                  var bg = XDictFrameCore.opaque(es.backgroundColor);
                  if (bg || es.backgroundImage !== 'none') what = 'background';
                  else if (['Top', 'Right', 'Bottom', 'Left'].some(function (sd) {
                    return parseFloat(es['border' + sd + 'Width']) > 0 && es['border' + sd + 'Style'] !== 'none';
                  })) what = 'border';
                  if (what) { boxes += 1; var k = what + ' ' + all[j].tagName.toLowerCase() + (all[j].className ? '.' + String(all[j].className).split(' ')[0] : ''); kinds[k] = (kinds[k] || 0) + 1; }
                }
                var top = Object.keys(kinds).sort(function (a, b) { return kinds[b] - kinds[a]; }).slice(0, 4)
                  .map(function (k) { return k + ' ×' + kinds[k]; });
                var imgs = Array.prototype.filter.call(document.images, function (i) { return i.getClientRects().length > 0; });
                var faces = Object.keys(families).sort(function (a, b) { return families[b] - families[a]; }).slice(0, 4)
                  .map(function (f) { return [f, chars ? Math.round(families[f] / chars * 1000) / 1000 : 0]; });
                var tokens = palette();
                var nonToken = Object.keys(colours).filter(function (c) { return !tokens[c]; })
                  .map(function (c) { return [c, colours[c].chars, colours[c].sample]; });
                return { colours: Object.keys(colours).map(function (c) { return [c, tokens[c] || null, colours[c].chars]; }),
                         nonToken: nonToken, proseFaceShare: prose ? proseFramed / prose : 1, lowestContrast: lowest, below45Share: chars ? below / chars : 0, families: faces, boxes: boxes, boxKinds: top, images: document.images.length, imagesShown: imgs.length,
                         leading: XDictFrameCore.dominant(leading),
                         dominant: size, left: left, right: root.clientWidth - right, width: root.clientWidth,
                         lineChars: size > 0 ? Math.round((right - left) / (size * 0.5)) : 0,
                         overflow: root.scrollWidth > root.clientWidth + 1,
                         bodyMaxWidth: body ? getComputedStyle(body).maxWidth : '',
                         xdictFontShare: chars ? framed / chars : 0, fixedContained: contained };
              }
              install();
              function start() { install(); name(document); }
              if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
              else start();
              window.addEventListener('load', start, { once: true });
              // A page script can remove or rewrite the frame's stylesheets or the theme; they come back, at most once
              // per change.
              new MutationObserver(function (records) {
                var hit = records.some(function (r) {
                  if (r.type === 'attributes' && r.target === document.documentElement) return true;
                  var gone = Array.prototype.some.call(r.removedNodes, function (n) { return ID.test(n.id || ''); });
                  var t = r.target.nodeType === 1 ? r.target : r.target.parentElement;
                  return gone || (t && ID.test(t.id || ''));
                });
                if (hit) install();
                records.forEach(function (r) {
                  Array.prototype.forEach.call(r.addedNodes, function (n) { if (n.nodeType === 1) name(n.parentNode || n); });
                });
              }).observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true,
                                                      attributeFilter: ['media', 'disabled', 'id', 'data-xdict-theme', 'data-xdict-face'] });
              window.__xdictFrame = { measure: measure };
            })();
            """
    }

    /// A JavaScript string literal for `text`, by JSON's own escaping.
    private static func jsString(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}

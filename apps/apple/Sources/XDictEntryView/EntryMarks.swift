import Foundation

/// **XDict's marks** (icon sweep 2026-10-15 §8; ADR-0010): the core marks what a dictionary drew, the frame draws XDict's
/// own in its place. Glyphs are CSS masks of inline `data:` SVG filled with `currentColor` (no route, no script); labels
/// are the core's text in one style; colours and sizes are tokens only.
extension EntryReadingFrame {
    /// A chevron to the trailing side, turned down when its fold is open (§8.1 `disclosure`).
    static let chevronSVG = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'>"
        + "<path d='M6 3.5l4.5 4.5L6 12.5' fill='none' stroke='black' stroke-width='1.5' stroke-linecap='round' "
        + "stroke-linejoin='round'/></svg>"

    /// An arrow to the trailing side (§8.1 `lookup`).
    static let arrowSVG = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'>"
        + "<path d='M2.5 8h10.5M9.5 4.5L13 8l-3.5 3.5' fill='none' stroke='black' stroke-width='1.5' "
        + "stroke-linecap='round' stroke-linejoin='round'/></svg>"

    /// A glyph box: 1em of the text it sits in, painted by `svg` as a mask in the text's colour.
    private static func glyph(_ svg: String) -> String {
        "content:\"\" !important;display:inline-block !important;width:var(--xdict-icon) !important;"
            + "height:var(--xdict-icon) !important;vertical-align:-0.15em !important;position:static !important;"
            + "float:none !important;font-size:inherit !important;border:0 !important;box-shadow:none !important;"
            + "background-color:currentColor !important;-webkit-mask:\(mask(svg)) center/contain no-repeat !important;"
            + "mask:\(mask(svg)) center/contain no-repeat !important"
    }

    /// Labels in the secondary colour with no box (R11): every label in the reading style.
    static let readingLabelsCSS = "[data-xdict-role=label]{color:var(--xdict-text-2) !important;"
        + "background:none !important;border:0 !important;padding:0 !important}"

    /// The marks' rules, after the controls' (`controlsCSS`), in the column layer.
    static var marksCSS: String {
        // In a cascade layer: a layered `!important` wins over every unlayered one whatever its specificity, so a
        // dictionary's own `li.x::before{content:"❑" !important}` (COBUILD, gallery 2026-10-16) cannot outrank XDict's.
        // 1. Where the core marked a pseudo-element, the dictionary's drawing goes first: its content, its sprite.
        "@layer xdict-marks{[data-xdict-before]::before,[data-xdict-after]::after{content:none !important;"
            + "background-image:none !important;-webkit-mask:none !important;mask:none !important}"
            // 2. The lookup arrow, on whichever side the dictionary drew its own.
            + "[data-xdict-before=lookup]::before,[data-xdict-after=lookup]::after{\(glyph(arrowSVG))}"
            + "[data-xdict-before=lookup]::before{margin:0 0.2em 0 0 !important;margin-inline:0 0.2em !important}"
            + "[data-xdict-after=lookup]::after{margin:0 0 0 0.2em !important;margin-inline:0.2em 0 !important}"
            // 3. The one marker: a 0.35em dot in the secondary text colour, at the head of the block.
            + "[data-xdict-before=marker]::before,[data-xdict-after=marker]::after{content:\"\" !important;"
            + "display:inline-block !important;width:0.35em !important;height:0.35em !important;"
            + "padding:0 !important;aspect-ratio:1 !important;box-sizing:content-box !important;"
            + "min-width:0 !important;min-height:0 !important;max-width:none !important;max-height:none !important;"
            + "line-height:0 !important;"
            + "background-color:var(--xdict-text-2) !important;border-radius:50% !important;"
            + "vertical-align:0.2em !important;position:static !important;float:none !important;"
            + "font-size:inherit !important;border:0 !important;box-shadow:none !important;transform:none !important}"
            + "[data-xdict-before=marker]::before{margin:0 0.35em 0 0 !important;margin-inline:0 0.35em !important}"
            + "[data-xdict-after=marker]::after{margin:0 0 0 0.35em !important;margin-inline:0.35em 0 !important}"
            // The leading dot hangs in a gutter of its own, centred on the first line box, whatever display the item's
            // content has: a block child would otherwise push the text to the line below the dot (COBUILD's examples).
            + "[data-xdict-before=marker]{position:relative !important;padding-inline-start:0.7em !important;"
            + "text-indent:0 !important}"
            // The gutter is the dot's: an item's first child pulled into it (OALD's `.cf`, -4px) starts at the text.
            + "[data-xdict-before=marker]>:first-child{margin-inline-start:0 !important}"
            + "[data-xdict-before=marker]::before{position:absolute !important;inset-inline-start:0 !important;"
            + "inset-block-start:calc(0.5lh - 0.175em) !important;margin:0 !important;line-height:inherit !important}"
            // 4. The disclosure chevron, drawn from `aria-expanded`, which the disclosure script keeps to the fold.
            + "[data-xdict-control=disclosure]::before{\(glyph(chevronSVG));margin:0 0.25em 0 0 !important;"
            + "margin-inline:0 0.25em !important;transition:transform 0.15s !important}"
            + "@media (prefers-reduced-motion:reduce){[data-xdict-control=disclosure]::before{transition:none !important}}"
            + "[data-xdict-before=lookup]:dir(rtl)::before,[data-xdict-after=lookup]:dir(rtl)::after,"
            + "[data-xdict-control=disclosure]:dir(rtl)::before{transform:scaleX(-1) !important}"
            + "[data-xdict-control=disclosure][aria-expanded=true]::before{transform:rotate(90deg) !important}"
            // A fold head's own vertical spacing goes: consecutive heads sit at the block gap.
            + "[data-xdict-control=disclosure]{margin-block:0 !important;"
            + "padding-block:0 !important}"
            // The chevron hangs in its own gutter on the head's first line box, as the marker does.
            + "[data-xdict-control=disclosure]{position:relative !important;"
            + "padding-inline-start:calc(var(--xdict-icon) + 0.25em) !important}"
            + "[data-xdict-control=disclosure]::before{position:absolute !important;inset-inline-start:0 !important;"
            + "inset-block-start:calc(0.5lh - var(--xdict-icon) / 2) !important;margin:0 !important}"
            // 5. The speaker: one inline row, the accent tag first, both on the line's baseline, the glyph centred on
            // the tag; whatever width, height, float or display the dictionary gave its button.
            + "[data-xdict-control=speaker]{display:inline-flex !important;align-items:center !important;"
            + "width:auto !important;height:auto !important;min-width:0 !important;min-height:0 !important;"
            + "float:none !important;position:static !important;vertical-align:baseline !important;"
            + "flex-wrap:nowrap !important;line-height:inherit !important;"
            // The control spacing before it: its hit area's negative margin, less 0.25em, so a speaker set against the
            // word before it (CED's after a transcription, COBUILD's after a headword) does not touch it.
            + "margin-inline-start:calc(0.25em - (var(--xdict-hit) - 1em) / 2) !important}"
            + "[data-xdict-control=speaker]>[data-xdict-tag]{order:-1 !important;margin-inline:0 0.56em !important}"
            // A box holding only speakers (the core's `data-xdict-speakers`) sits on its transcription's line.
            + "[data-xdict-speakers]{display:inline !important;float:none !important;position:static !important;"
            + "margin-block:0 !important}"
            // A box of speakers leading its block floats at the line's start, so the transcription's block after it
            // (CEPD's `sense-body`) begins its first line beside it.
            + "[data-xdict-speakers=lead]{float:inline-start !important;margin-inline-end:0.35em !important}"
            // A speaker and the transcription it plays are one run (`pronRunDOM`): no break inside it but within the
            // transcription itself.
            + "[data-xdict-pron-run]{white-space:nowrap !important}"
            + "[data-xdict-pron-run] [data-xdict-phon]{white-space:normal !important}"
            // A tag wrapped deeper in its speaker (OED's) owns its gap too (§8.4); 0.56em of its 0.625em is 0.35em of the text.
            + "[data-xdict-control=speaker] [data-xdict-tag]{margin-inline-end:0.56em !important}"
            + "[data-xdict-control=speaker]>[data-xdict-icon]{margin-inline:0 0.35em !important}"
            // 6. Labels are sized by their text, not by the badge's box the dictionary sized for its drawing.
            + "[data-xdict-role=label][data-xdict-label=level],[data-xdict-role=label][data-xdict-label=wordlist],"
            + "[data-xdict-role=label][data-xdict-label=frequency],[data-xdict-role=label][data-xdict-label=new]"
            + "{display:inline !important;width:auto !important;height:auto !important;min-width:0 !important;"
            + "min-height:0 !important;float:none !important;position:static !important}"
            // A wrapper holding only labels and the graphics they replaced is sized by the labels, not the drawing.
            + ":has(> [data-xdict-labelled]):not(:has(> :not([data-xdict-labelled],[data-xdict-role=label])))"
            + "{width:auto !important;min-width:0 !important;height:auto !important;min-height:0 !important}"
            // A fold head's wrapper adds no vertical space of its own around it.
            + ":has(> [data-xdict-control=disclosure]),:has(> :only-child > [data-xdict-control=disclosure])"
            + "{margin-block:0 !important;padding-block:0 !important}"
            // A label owns 0.35em after it before the next word or control (§8.4); two labels in a row share it.
            + "[data-xdict-role=label]{margin-inline-end:0.35em !important}"
            + "[data-xdict-role=label]+[data-xdict-role=label]{margin-inline-start:0 !important}"
            // 7. Punctuation the source set against an element stays against it: its inline end spacing goes.
            // A speaker's tag is drawn first (order -1), never last; a label that replaced the hugging element's last
            // child is its last drawn text.
            + "[data-xdict-hug],[data-xdict-hug] :last-child:not([data-xdict-tag]),"
            + "[data-xdict-hug] [data-xdict-role=label]:has(+ [data-xdict-labelled]:last-child)"
            + "{margin-inline-end:0 !important;"
            + "padding-inline-end:0 !important}"
            // A graphic the core turned into a label stays hidden, whatever display the dictionary gives images.
            + "[data-xdict-labelled]{display:none !important}}"
            // 8. Labels: one style, plain text in the secondary colour, no box (R11).
            + "[data-xdict-role=label]{font-family:var(--xdict-font);font-style:normal;font-size:var(--xdict-fs-xs);"
            + "font-weight:var(--xdict-weight-bold);letter-spacing:0.02em;"
            + "white-space:nowrap;vertical-align:baseline;margin-inline-start:0.25em}"
            // A label replacing a drawing is XDict's in both styles; one read from the dictionary's words takes this
            // colour and loses its box in the reading style only (`readingLabelsCSS`): in original style it keeps the
            // dictionary's, chosen for the box it sits on (LDOCE's GRAMMAR heading on cyan read 2.34:1 in grey).
            + "[data-xdict-role=label]:is([data-xdict-label=level],[data-xdict-label=wordlist],"
            + "[data-xdict-label=frequency],[data-xdict-label=new]){color:var(--xdict-text-2) !important;"
            + "background:none !important;border:0 !important;padding:0 !important}"
            + "[data-xdict-role=label][data-xdict-label=level],[data-xdict-role=label][data-xdict-label=wordlist]"
            + "{font-variant-numeric:lining-nums}"
            + "[data-xdict-role=label][data-xdict-label=frequency]{letter-spacing:0.08em}"
            + "[data-xdict-role=label][data-xdict-label=new]{font-variant-caps:all-small-caps;font-size:var(--xdict-fs-s)}"
            // Sense numbers: plain numerals, bold as the headword, with no circle or box.
            + "[data-xdict-role=sensenum]{font-weight:var(--xdict-weight-bold);font-style:normal;"
            + "font-variant-numeric:lining-nums tabular-nums;background:none !important;border:0 !important;"
            + "border-radius:0 !important;margin-inline-end:0.25em}"
    }
}

extension EntryScripts {
    /// The disclosure state, with no DOM: each fold head's `aria-expanded` is whether the element it folds is shown. The
    /// folded element is the one `aria-controls` names, else the next element after the head, or after a wrapper of it
    /// (up to two levels: a title span inside a box's head). No folded element: no state is claimed. Writes only on a
    /// change, and at most `MAX` heads a pass.
    static let disclosureCore = #"""
        var XDictDisclosureCore = (function () {
          'use strict';
          var MAX = 2000;
          function target(control, byId) {
            var id = control.getAttribute('aria-controls');
            if (id) { var named = byId(id); if (named) return named; }
            for (var e = control, up = 0; e && up < 3; e = e.parentElement, up++) {
              if (e.nextElementSibling) return e.nextElementSibling;
            }
            return null;
          }
          function sync(controls, byId, shown) {
            var changed = 0;
            for (var i = 0; i < controls.length && i < MAX; i++) {
              var c = controls[i], t = target(c, byId);
              if (!t) continue;
              var v = shown(t) ? 'true' : 'false';
              if (c.getAttribute('aria-expanded') !== v) { c.setAttribute('aria-expanded', v); changed += 1; }
            }
            return changed;
          }
          return { MAX: MAX, target: target, sync: sync };
        })();
        """#

    /// The disclosure state on the page, in the shell's world: synced after load, after any change of a class, style,
    /// `hidden` or `open` (debounced), and after every click, once the page's own handlers have run. It writes only
    /// `aria-expanded` and `role`, which no fold script reads, and never handles a click, so the dictionary's fold
    /// script works as it always did. `__xdictDisclosure.expand(open)` clicks every head not yet in that state, as a
    /// reader would, and answers how many it clicked: "Expand All" and "Collapse All".
    static let disclosureDOM = #"""
        (function () {
          'use strict';
          if (typeof document === 'undefined' || typeof window === 'undefined' || window.__xdictDisclosure) return;
          var SELECTOR = '[data-xdict-control=disclosure]';
          function byId(id) { return document.getElementById(id); }
          function shown(el) {
            return typeof el.checkVisibility === 'function'
              ? el.checkVisibility({ visibilityProperty: true }) : el.getClientRects().length > 0;
          }
          function sync() {
            queued = false;
            var controls = document.querySelectorAll(SELECTOR);
            for (var i = 0; i < controls.length && i < XDictDisclosureCore.MAX; i++) {
              var c = controls[i];
              if (c.tagName !== 'A' && c.tagName !== 'BUTTON' && !c.hasAttribute('role')) c.setAttribute('role', 'button');
            }
            return XDictDisclosureCore.sync(controls, byId, shown);
          }
          var queued = false;
          function later() { if (!queued) { queued = true; setTimeout(sync, 16); } }
          function expand(open) {
            sync();
            var want = open ? 'false' : 'true', clicked = 0;
            var controls = document.querySelectorAll(SELECTOR);
            for (var i = 0; i < controls.length && i < XDictDisclosureCore.MAX; i++) {
              var c = controls[i], href = c.getAttribute('href');
              // A head that is a link elsewhere is followed, not folded: never clicked for the reader.
              if (c.getAttribute('aria-expanded') !== want || (href !== null && href.charAt(0) !== '#')) continue;
              c.click();
              clicked += 1;
            }
            sync();
            return clicked;
          }
          function start() {
            sync();
            new MutationObserver(later).observe(document.documentElement, { subtree: true, childList: true,
              attributes: true, attributeFilter: ['class', 'style', 'hidden', 'open'] });
          }
          document.addEventListener('click', later, true);
          document.addEventListener('transitionend', later, true);
          document.addEventListener('animationend', later, true);
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
          else start();
          window.addEventListener('load', later, { once: true });
          window.__xdictDisclosure = { sync: sync, expand: expand };
        })();
        """#

    /// **A speaker and the transcription it plays stay on one line** (CALD "remember sb to sb" broke between them):
    /// the run from a speaker, through blanks and other speakers, to the next sibling transcription. No DOM: `is`
    /// says what a node is, so the rule is tested alone. `null` when anything else comes first.
    static let pronRunCore = #"""
        var XDictPronRunCore = (function () {
          'use strict';
          function run(speaker, is) {
            var n = speaker.nextSibling, steps = 0;
            while (n && steps < 32) {
              if (is.phon(n)) return { first: speaker, last: n };
              if (!is.blank(n) && !is.speaker(n)) return null;
              n = n.nextSibling; steps += 1;
            }
            return null;
          }
          return { run: run };
        })();
        """#

    /// The run on the page, in the shell's world: wrapped once in `data-xdict-pron-run`, which the marks keep from
    /// breaking (the break goes before the speaker); the transcription inside still wraps within itself.
    static let pronRunDOM = #"""
        (function () {
          'use strict';
          if (typeof document === 'undefined' || window.__xdictPronRun) return;
          var is = {
            speaker: function (n) { return n.nodeType === 1 && n.getAttribute('data-xdict-control') === 'speaker'; },
            phon: function (n) { return n.nodeType === 1 && n.hasAttribute('data-xdict-phon'); },
            blank: function (n) { return n.nodeType === 3 && !/\S/.test(n.nodeValue); }
          };
          var MAX = 2000;
          function glue() {
            var speakers = document.querySelectorAll('[data-xdict-control=speaker]'), done = 0;
            for (var i = 0; i < speakers.length && i < MAX; i++) {
              var s = speakers[i];
              if (!s.parentNode || s.parentNode.hasAttribute && s.parentNode.hasAttribute('data-xdict-pron-run')) continue;
              var prev = s.previousSibling;
              while (prev && is.blank(prev)) prev = prev.previousSibling;
              if (prev && is.speaker(prev)) continue;
              var r = XDictPronRunCore.run(s, is);
              if (!r) continue;
              var wrap = document.createElement('span');
              wrap.setAttribute('data-xdict-pron-run', '');
              s.parentNode.insertBefore(wrap, s);
              var n = s, stop = r.last.nextSibling;
              while (n && n !== stop) { var next = n.nextSibling; wrap.appendChild(n); n = next; }
              done += 1;
            }
            return done;
          }
          function start() { window.__xdictPronRun = { glued: glue() }; }
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
          else start();
        })();
        """#
}

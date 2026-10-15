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
            + "background-color:var(--xdict-text-2) !important;border-radius:50% !important;"
            + "vertical-align:0.2em !important;position:static !important;float:none !important;"
            + "font-size:inherit !important;border:0 !important;box-shadow:none !important;transform:none !important}"
            + "[data-xdict-before=marker]::before{margin:0 0.35em 0 0 !important;margin-inline:0 0.35em !important}"
            + "[data-xdict-after=marker]::after{margin:0 0 0 0.35em !important;margin-inline:0.35em 0 !important}"
            // 4. The disclosure chevron, drawn from `aria-expanded`, which the disclosure script keeps to the fold.
            + "[data-xdict-control=disclosure]::before{\(glyph(chevronSVG));margin:0 0.25em 0 0 !important;"
            + "margin-inline:0 0.25em !important;transition:transform 0.15s !important}"
            + "@media (prefers-reduced-motion:reduce){[data-xdict-control=disclosure]::before{transition:none !important}}"
            + "[data-xdict-before=lookup]:dir(rtl)::before,[data-xdict-after=lookup]:dir(rtl)::after,"
            + "[data-xdict-control=disclosure]:dir(rtl)::before{transform:scaleX(-1) !important}"
            + "[data-xdict-control=disclosure][aria-expanded=true]::before{transform:rotate(90deg) !important}}"
            // 5. Labels: one style, plain text in the secondary colour, no box (R11).
            + "[data-xdict-role=label]{font-family:var(--xdict-font);font-style:normal;font-size:var(--xdict-fs-xs);"
            + "font-weight:var(--xdict-weight-bold);color:var(--xdict-text-2) !important;letter-spacing:0.02em;"
            + "white-space:nowrap;vertical-align:baseline;margin-inline-start:0.25em;background:none !important;"
            + "border:0 !important;padding:0 !important}"
            + "[data-xdict-role=label][data-xdict-label=level],[data-xdict-role=label][data-xdict-label=wordlist]"
            + "{font-variant-numeric:lining-nums}"
            + "[data-xdict-role=label][data-xdict-label=frequency]{letter-spacing:0.08em}"
            + "[data-xdict-role=label][data-xdict-label=new]{font-variant-caps:all-small-caps;font-size:var(--xdict-fs-s)}"
            // Sense numbers: plain numerals, bold as the headword, with no circle or box.
            + "[data-xdict-role=sensenum]{font-weight:var(--xdict-weight-bold);font-style:normal;"
            + "font-variant-numeric:lining-nums tabular-nums;background:none !important;border:0 !important;"
            + "border-radius:0 !important;margin-inline-end:0.25em}"
            // A graphic the core turned into a label stays hidden, whatever display the dictionary gives images.
            + "[data-xdict-labelled]{display:none !important}"
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
}

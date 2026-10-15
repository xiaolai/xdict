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
    static let findCore = #"""
        var XDictFindCore = (function () {
          'use strict';
          function pattern(query) {
            var words = String(query).trim().split(/\s+/).filter(function (w) { return w.length > 0; });
            if (words.length === 0) return null;
            var escaped = words.map(function (w) { return w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); });
            return new RegExp(escaped.join('\\s+'), 'giu');
          }
          function matches(text, query) {
            var re = pattern(query), out = [], m;
            if (!re) return out;
            while ((m = re.exec(text)) !== null) {
              if (m[0].length === 0) { re.lastIndex += 1; continue; }
              out.push([m.index, m.index + m[0].length]);
            }
            return out;
          }
          return { pattern: pattern, matches: matches };
        })();
        """#

    /// Find over the document: the text the reader can see and the text folded away (an ancestor with no box, or
    /// `visibility: hidden`) are read apart, each as one string with a line break wherever a block or `<br>` breaks the
    /// flow, as `innerText` reads it. Visible matches are highlighted and stepped through; hidden ones only counted.
    static let findDOM = #"""
        (function () {
          'use strict';
          if (window.__xdictFind) return;
          var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, TEXTAREA: 1, SELECT: 1, OPTION: 1, HEAD: 1, TITLE: 1 };
          function inline(display) {
            return display === 'contents' || display.indexOf('inline') === 0 || display.indexOf('ruby') === 0;
          }
          function blockOf(node, cache) {
            var el = node.parentElement;
            while (el && el !== document.body && el !== document.documentElement) {
              var d = cache.get(el);
              if (d === undefined) { d = getComputedStyle(el).display; cache.set(el, d); }
              if (!inline(d)) return el;
              el = el.parentElement;
            }
            return el;
          }
          function visible(el, cache) {
            var v = cache.get(el);
            if (v === undefined) {
              v = typeof el.checkVisibility === 'function'
                ? el.checkVisibility({ visibilityProperty: true })
                : el.getClientRects().length > 0;
              cache.set(el, v);
            }
            return v;
          }
          function read() {
            var displays = new Map(), shown = new Map();
            var runs = { visible: { text: '', nodes: [] }, hidden: { text: '', nodes: [] } };
            var last = { visible: null, hidden: null };
            var root = document.body || document.documentElement;
            if (!root) return runs;
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
              acceptNode: function (n) {
                if (n.nodeType === 1) {
                  if (SKIP[n.tagName]) return NodeFilter.FILTER_REJECT;
                  return n.tagName === 'BR' ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
                }
                return n.nodeValue.length ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
              }
            });
            var n;
            while ((n = walker.nextNode())) {
              if (n.nodeType === 1) {
                runs.visible.text += '\n'; runs.hidden.text += '\n';
                last.visible = null; last.hidden = null;
                continue;
              }
              var parent = n.parentElement;
              if (!parent) continue;
              var kind = visible(parent, shown) ? 'visible' : 'hidden';
              var block = blockOf(n, displays), run = runs[kind];
              if (last[kind] !== null && last[kind] !== block) run.text += '\n';
              last[kind] = block;
              run.nodes.push({ node: n, start: run.text.length });
              run.text += n.nodeValue;
            }
            return runs;
          }
          function locate(nodes, offset) {
            var lo = 0, hi = nodes.length - 1;
            while (lo < hi) {
              var mid = (lo + hi + 1) >> 1;
              if (nodes[mid].start <= offset) lo = mid; else hi = mid - 1;
            }
            return nodes[lo];
          }
          function toRange(nodes, s, e) {
            var a = locate(nodes, s), b = locate(nodes, e - 1), r = document.createRange();
            r.setStart(a.node, Math.min(s - a.start, a.node.nodeValue.length));
            r.setEnd(b.node, Math.min(e - b.start, b.node.nodeValue.length));
            return r;
          }
          var state = { ranges: [], hidden: 0, current: -1 };
          function ensureStyle() {
            if (document.getElementById('xdict-find-style')) return;
            var s = document.createElement('style');
            s.id = 'xdict-find-style';
            s.textContent = '::highlight(xdict-find){background-color:#ffe36e;color:#000}'
              + '::highlight(xdict-find-current){background-color:#ff9632;color:#000}';
            (document.head || document.documentElement).appendChild(s);
          }
          function paint() {
            if (typeof Highlight === 'undefined' || !window.CSS || !CSS.highlights) return;
            CSS.highlights.set('xdict-find', new Highlight(...state.ranges));
            if (state.current >= 0) CSS.highlights.set('xdict-find-current', new Highlight(state.ranges[state.current]));
            else CSS.highlights.delete('xdict-find-current');
          }
          function reveal() {
            var r = state.ranges[state.current];
            var el = r && (r.startContainer.nodeType === 1 ? r.startContainer : r.startContainer.parentElement);
            if (el) el.scrollIntoView({ block: 'center', inline: 'nearest' });
          }
          function report() { return { visible: state.ranges.length, hidden: state.hidden, current: state.current + 1 }; }
          window.__xdictFind = {
            find: function (query) {
              var runs = read();
              state.ranges = XDictFindCore.matches(runs.visible.text, query).map(function (m) {
                return toRange(runs.visible.nodes, m[0], m[1]);
              });
              state.hidden = XDictFindCore.matches(runs.hidden.text, query).length;
              state.current = state.ranges.length ? 0 : -1;
              ensureStyle(); paint(); reveal();
              return report();
            },
            step: function (forward) {
              if (!state.ranges.length) return report();
              var n = state.ranges.length;
              state.current = (state.current + (forward ? 1 : n - 1)) % n;
              paint(); reveal();
              return report();
            },
            clear: function () {
              state = { ranges: [], hidden: 0, current: -1 };
              if (window.CSS && CSS.highlights) { CSS.highlights.delete('xdict-find'); CSS.highlights.delete('xdict-find-current'); }
              return report();
            }
          };
        })();
        """#

    /// Contrast arithmetic, with no DOM: WCAG's contrast ratio, for the gallery's measurement (`frameDOM`'s `measure`).
    /// It corrects nothing: the palette's tokens read on every surface by construction (`colour.rs`).
    static let readabilityCore = #"""
        var XDictReadability = (function () {
          'use strict';
          function parse(css) {
            var m = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,\/]\s*([\d.]+)(%?))?\s*\)$/.exec(String(css).trim());
            if (!m) return null;
            var a = m[4] === undefined ? 1 : parseFloat(m[4]) / (m[5] === '%' ? 100 : 1);
            return [parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3]), a];
          }
          function channel(v) { v = v / 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
          function luminance(c) { return 0.2126 * channel(c[0]) + 0.7152 * channel(c[1]) + 0.0722 * channel(c[2]); }
          function contrast(a, b) {
            var x = luminance(a), y = luminance(b);
            return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
          }
          return { parse: parse, contrast: contrast };
        })();
        """#

    /// The page drawn light or dark (`EntryColourScheme`), at document start with the scheme baked in so nothing
    /// flashes; then the frame, and the guard over the colours the page's own scripts write (`colourGuard`). No colour
    /// is corrected here: the core and the palette own colour (ADR-0010).
    static func appearance(_ scheme: EntryColourScheme, frame: EntryReadingFrame = .all,
                           labels: EntryReadingFrame.SpeakerLabels = .localized) -> String {
        frameCore + "\n" + frameDOM(frame, scheme: scheme, labels: labels) + "\n" + colourCore + "\n" + colourGuard + "\n"
            + """
        (function () {
          'use strict';
          var mode = '\(scheme.rawValue)';
          var css = (mode === 'dark'
            ? 'html{color-scheme:dark;background-color:rgb(30,30,30);color:rgb(230,230,230)}'
            : 'html{color-scheme:light;background-color:rgb(255,255,255)}') + '\(readingInset)';
          function install() {
            var s = document.getElementById('xdict-appearance-style');
            if (!s) {
              s = document.createElement('style');
              s.id = 'xdict-appearance-style';
              (document.head || document.documentElement).appendChild(s);
            }
            s.textContent = css;
          }
          install();
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, { once: true });
          else install();
          window.__xdictAppearance = { mode: mode };
        })();
        """
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

    static let handlerName = "xdictEntry"

    /// The shell's scripts, in the order they are installed at document start, before any of the page's.
    static func installed(_ scheme: EntryColourScheme, frame: EntryReadingFrame) -> [String] {
        [findCore, findDOM, readabilityCore, appearance(scheme, frame: frame), placeholderClicks, speakerClicks]
    }

    /// **A click on XDict's speaker is XDict's** (the core marks it `data-xdict-control="speaker"`): on the window, in
    /// the capture phase, installed before any page script, so it runs first. It stops the click going further into
    /// the page, whose own handler would otherwise cancel it and play the recording itself (COBUILD's, from an `addr`
    /// XDict never serves), and leaves the default alone: the link's navigation, which the router answers. Untrusted
    /// clicks too: a page's or an instrument's `click()` on a speaker means the same. Every other click is the page's.
    static let speakerClicks = #"""
        (function () {
          'use strict';
          window.addEventListener('click', function (e) {
            var t = e.target, c = t && t.closest ? t.closest('a[href][data-xdict-control="speaker"]') : null;
            if (c) e.stopImmediatePropagation();
          }, true);
        })();
        """#

    /// A reader's click on a blocked image's placeholder asks the same question as a remote link. Trusted clicks only:
    /// a script's `click()` or `dispatchEvent` is not the reader. An image inside a link is left to the link.
    static let placeholderClicks = #"""
        (function () {
          'use strict';
          document.addEventListener('click', function (e) {
            if (!e.isTrusted) return;
            var t = e.target, img = t && t.closest ? t.closest('img') : null;
            if (!img || img.closest('a[href]')) return;
            var src = img.currentSrc || img.src || '';
            if (src.indexOf('xdict://d/blocked/') !== 0) return;
            e.preventDefault();
            try { webkit.messageHandlers.xdictEntry.postMessage({ kind: 'blocked-image', url: src }); } catch (x) {}
          }, true);
        })();
        """#
}

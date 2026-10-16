import Foundation

/// **The shell owns the colours a page's scripts write** (ADR-0010). The core maps every colour in the entry's HTML and
/// CSS to a palette token, but it cannot see a script's run-time `style.color = '#000'` (ODE's `o3.js` on `.tki`). The
/// guard maps those in the shell's world, by the core's rule, and drops what "Plain by default" drops.
extension EntryScripts {
    /// The palette's light values, the fallback each token is written with, as the core writes it (`colour.rs`).
    private static var fallbacksJSON: String {
        let pairs = Dictionary(uniqueKeysWithValues: EntryReadingFrame.colours.map { ($0.0, $0.1) })
        let data = (try? JSONSerialization.data(withJSONObject: pairs, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The core's rule, with no DOM (`core/xdict-entry/src/colour.rs`; parity with it is
    /// `conformance/fixtures/colour-tokens.tsv`): a text colour read in OKLCH, made opaque over white. Near-white is
    /// `--xdict-text`, a neutral (C < 0.035) is `--xdict-text` below L 0.45 and `--xdict-text-2` above, anything else
    /// the one accent, `--xdict-accent` (owner, 2026-10-16: flatten). `plan` is what one element's inline declarations become.
    static var colourCore: String {
        """
        var XDictColourCore = (function () {
          'use strict';
          var FALLBACK = \(fallbacksJSON);
          var HEX = /^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i;
          var RGB = /^rgba?\\(\\s*([\\d.]+%?)[,\\s]+([\\d.]+%?)[,\\s]+([\\d.]+%?)(?:\\s*[,\\/]\\s*([\\d.]+%?))?\\s*\\)$/i;
          function parse(css) {
            var v = String(css).trim(), m = HEX.exec(v);
            if (m) {
              var h = m[1];
              if (h.length <= 4) h = h.split('').map(function (x) { return x + x; }).join('');
              var n = function (i) { return parseInt(h.slice(i, i + 2), 16); };
              return [n(0), n(2), n(4), h.length === 8 ? n(6) / 255 : 1];
            }
            m = RGB.exec(v);
            if (!m) return null;
            var ch = function (x) { var f = parseFloat(x); return Math.min(255, Math.max(0, /%$/.test(x) ? f * 2.55 : f)); };
            var a = m[4] === undefined ? 1 : parseFloat(m[4]) / (/%$/.test(m[4]) ? 100 : 1);
            return [ch(m[1]), ch(m[2]), ch(m[3]), Math.min(1, Math.max(0, a))];
          }
          function linear(c) { c = c / 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
          function lch(c) {
            var w = function (x) { return x * c[3] + 255 * (1 - c[3]); };
            var r = linear(w(c[0])), g = linear(w(c[1])), b = linear(w(c[2]));
            var l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
            var m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
            var s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
            var L = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s;
            var A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
            var B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
            return { l: L, c: Math.hypot(A, B), h: Math.atan2(B, A) };
          }
          function token(c) {
            var p = lch(c);
            if (p.l >= 0.95 && p.c < 0.03) return 'text';
            if (p.c < 0.035) return p.l < 0.45 ? 'text' : 'text-2';
            return 'accent';
          }
          function text(c) {
            if (!c) return null;
            var t = token(c);
            return 'var(--xdict-' + t + ', ' + FALLBACK[t] + ')';
          }
          // What the core drops inside an entry ("Plain by default"), and a fill colour that would override the token.
          var DROP = /^(background|border|outline|box-shadow$|text-shadow$|-webkit-text-fill-color$)/;
          var NOTHING = /^(0|0px|none|hidden)$/i;
          var LEFT = /^(inherit|initial|unset|revert|revert-layer|currentcolor|transparent)$/i;
          // `declarations`: [name, value, priority] of one element's inline style; `resolve`: a CSS colour to RGBA.
          // A token, a keyword and a value the resolver cannot read are left alone, so the guard never rewrites its own.
          function plan(declarations, resolve) {
            var out = [];
            declarations.forEach(function (d) {
              var name = String(d[0]), value = String(d[1]).trim();
              // A border that draws nothing (the core's `<hr>` gap, Q9) stays: removing it brings back the UA's line.
              var none = /^(border|outline)/.test(name) && NOTHING.test(value);
              if (DROP.test(name)) { if (!none) out.push(['remove', name]); return; }
              if (name !== 'color' || /^var\\(\\s*--xdict-/.test(value) || /var\\(/.test(value) || LEFT.test(value)) return;
              var css = text(resolve(value));
              if (css && css !== value) out.push(['set', 'color', css, d[2] || '']);
            });
            return out;
          }
          return { parse: parse, token: token, text: text, plan: plan };
        })();
        """
    }

    /// The guard on the page: style attributes changed and elements added are queued, and a capped batch is mapped per
    /// animation frame (a timer stands in where no frame comes), with the observer disconnected while it writes, so its
    /// own writes never queue more. `window.__xdictColours` (the shell's world only) counts what it did.
    static let colourGuard = #"""
        (function () {
          'use strict';
          if (window.__xdictColours) return;
          var BATCH = 200, queue = new Set(), scheduled = false;
          var stats = { mapped: 0, dropped: 0, batches: 0, deferred: 0 };
          var paint = null;
          // Any CSS colour to RGBA through a canvas's own parser; a value it cannot read leaves both sentinels apart.
          function resolve(value) {
            var c = XDictColourCore.parse(value);
            if (c) return c;
            if (!paint) paint = document.createElement('canvas').getContext('2d');
            if (!paint) return null;
            paint.fillStyle = '#000'; paint.fillStyle = value; var a = paint.fillStyle;
            paint.fillStyle = '#fff'; paint.fillStyle = value;
            return a === paint.fillStyle ? XDictColourCore.parse(a) : null;
          }
          function apply(el) {
            var s = el.style;
            if (!el.isConnected || !s || !s.length) return;
            var declarations = [];
            for (var i = 0; i < s.length; i++) declarations.push([s[i], s.getPropertyValue(s[i]), s.getPropertyPriority(s[i])]);
            XDictColourCore.plan(declarations, resolve).forEach(function (a) {
              if (a[0] === 'remove') { s.removeProperty(a[1]); stats.dropped += 1; }
              else { s.setProperty(a[1], a[2], a[3]); stats.mapped += 1; }
            });
          }
          function collect(records) {
            records.forEach(function (r) {
              if (r.type === 'attributes') { if (r.target.nodeType === 1) queue.add(r.target); return; }
              Array.prototype.forEach.call(r.addedNodes, function (n) {
                if (n.nodeType !== 1) return;
                if (n.hasAttribute('style')) queue.add(n);
                if (n.firstElementChild) Array.prototype.forEach.call(n.querySelectorAll('[style]'), function (e) { queue.add(e); });
              });
            });
          }
          var observer = new MutationObserver(function (records) { collect(records); schedule(); });
          function watch() {
            observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true,
                                                         attributeFilter: ['style'] });
          }
          function run() {
            scheduled = false;
            collect(observer.takeRecords());
            observer.disconnect();
            var n = 0;
            for (var el of queue) {
              queue.delete(el);
              try { apply(el); } catch (e) {}
              if (++n >= BATCH) break;
            }
            stats.batches += 1;
            watch();
            if (queue.size) { stats.deferred += 1; schedule(); }
          }
          function schedule() {
            if (scheduled) return;
            scheduled = true;
            var done = false;
            var once = function () { if (!done) { done = true; run(); } };
            requestAnimationFrame(once);
            setTimeout(once, 100);
          }
          watch();
          window.__xdictColours = { stats: function () { return Object.assign({ queued: queue.size }, stats); } };
        })();
        """#
}

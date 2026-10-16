import Foundation

/// **Unification R's mechanical invariants** (owner, 2026-10-16; `dev-docs/artifacts/reading-frame/unify/` §11.7), on
/// a rendered framed entry, every value that breaks one listed: every visible character's size is a step of the scale
/// (12, 14, 16, 18, 20, 24 px); its leading is 1.6, or 1.3 at 20 px and above; every block's vertical margins are 0
/// or a space token (4, 8, 12, 16, 24 px, either sign); every transcription character is in the IPA face; every text
/// colour is text, text-2, link or the accent of the theme.
extension GalleryRun {
    /// One check's result: characters checked, characters off, and the values off with their characters.
    static let invariantsScript = #"""
        var SIZES = [12, 14, 16, 18, 20, 24], SPACE = [0, 4, 8, 12, 16, 24];
        function near(v, set) { return set.some(function (s) { return Math.abs(Math.abs(v) - s) < 0.51; }); }
        var checks = { size: {}, leading: {}, margin: {}, phonFace: {}, colour: {}, lead: {}, markerInWord: {}, listMarkers: {}, cellWords: {}, punctLine: {}, wordGap: {} };
        Object.keys(checks).forEach(function (k) { checks[k] = { total: 0, off: 0, values: {} }; });
        function note(check, ok, n, value) {
          var c = checks[check]; c.total += n;
          if (!ok) { c.off += n; c.values[value] = (c.values[value] || 0) + n; }
        }
        var probe = document.createElement('span'), allowed = {};
        (document.body || document.documentElement).appendChild(probe);
        ['text', 'text-2', 'link', 'accent'].forEach(function (t) {
          probe.style.color = 'var(--xdict-' + t + ')'; allowed[getComputedStyle(probe).color] = t;
        });
        probe.style.color = '';
        probe.style.fontFamily = 'var(--xdict-font-phon)';
        var PHON = getComputedStyle(probe).fontFamily.split(',')[0].replace(/["']/g, '').trim();
        probe.remove();
        var walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
        for (var n = walker.nextNode(); n; n = walker.nextNode()) {
          var t = n.nodeValue.replace(/\s+/g, ''), el = n.parentElement;
          if (!t.length || !el) continue;
          var r = document.createRange(); r.selectNodeContents(n);
          if (!r.getClientRects().length) continue;
          var cs = getComputedStyle(el), fs = parseFloat(cs.fontSize), k = t.length;
          var label = el.tagName.toLowerCase() + (el.className ? '.' + String(el.className).split(' ')[0] : '');
          note('size', near(fs, SIZES), k, Math.round(fs * 10) / 10 + 'px <' + label + '>');
          var lh = cs.lineHeight === 'normal' ? NaN : parseFloat(cs.lineHeight) / fs, want = fs >= 19.5 ? 1.3 : 1.6;
          note('leading', Math.abs(lh - want) < 0.03, k, (isNaN(lh) ? 'normal' : Math.round(lh * 100) / 100) + ' at ' + Math.round(fs) + 'px <' + label + '>');
          var phon = el.closest('[data-xdict-phon]');
          if (phon && !/^font:/.test(phon.getAttribute('data-xdict-phon-system') || '') && !el.closest('[data-xdict-tag]')) {
            note('phonFace', cs.fontFamily.split(',')[0].replace(/["']/g, '').trim() === PHON, k, cs.fontFamily.split(',')[0] + ' <' + label + '>');
          }
          if (!/^rgba\(.*,\s*0\)$/.test(cs.color)) note('colour', !!allowed[cs.color], k, cs.color + ' <' + label + '>');
          // The lead's own text (not a transcription or a label inside it) is the lead's look: 24 px, text colour.
          var lead = el.closest('[data-xdict-lead]');
          if (lead && !el.closest('[data-xdict-phon],[data-xdict-role=label],[data-xdict-tag]')) {
            var role = el.closest('[data-xdict-role]');
            if (role && (role === lead || role.getAttribute('data-xdict-role') === 'headword')) {
              var ok = Math.abs(fs - 24) < 0.51 && allowed[cs.color] === 'text';
              note('lead', ok, k, Math.round(fs) + 'px ' + cs.color + ' <' + label + '>');
            }
          }
        }
        // An entry with a headword has a lead.
        if (document.querySelector('[data-xdict-role=headword]')) {
          note('lead', !!document.querySelector('[data-xdict-lead]'), 1, 'no lead in the entry');
        }
        // A marker is never drawn between two letters of a word.
        function edge(node, back) {
          var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          w.currentNode = node;
          var t = back ? w.previousNode() : (function () {
            var last = node; while (last.lastChild) last = last.lastChild; w.currentNode = last; return w.nextNode();
          })();
          while (t && !t.nodeValue.length) t = back ? w.previousNode() : w.nextNode();
          if (!t || node.contains(t)) return '';
          return back ? t.nodeValue.slice(-1) : t.nodeValue.charAt(0);
        }
        document.querySelectorAll('[data-xdict-before=marker],[data-xdict-after=marker]').forEach(function (m) {
          if (!m.getClientRects().length) return;
          // Inside a word: text right before and right after it in the same parent, one inline run, its letters
          // touching the marker. A block boundary is not the inside of a word.
          var p = m.previousSibling, n = m.nextSibling;
          var inside = /^inline/.test(getComputedStyle(m).display) && p && n && p.nodeType === 3 && n.nodeType === 3
            && /[\p{L}\p{N}]$/u.test(p.nodeValue) && /^[\p{L}\p{N}]/u.test(n.nodeValue);
          note('markerInWord', !inside, 1, edge(m, true) + '•' + edge(m, false) + ' <' + m.tagName.toLowerCase() + '.' + String(m.className).split(' ')[0] + '>');
        });
        var all = document.body ? document.body.getElementsByTagName('*') : [];
        for (var i = 0; i < all.length && i < 20000; i++) {
          var e = all[i];
          if (e.closest('[data-xdict-control],[data-xdict-icon],svg') || !e.getClientRects().length) continue;
          var es = getComputedStyle(e);
          if (/^inline|^contents|^none|^table-cell|^table-row/.test(es.display)) continue;
          [es.marginTop, es.marginBottom].forEach(function (m) {
            var v = parseFloat(m);
            note('margin', near(v, SPACE), 1, Math.round(v * 10) / 10 + 'px <' + e.tagName.toLowerCase() + (e.className ? '.' + String(e.className).split(' ')[0] : '') + '>');
          });
        }
        // One list, one marker: where any item of a list carries XDict's marker, every item does, never the
        // dictionary's bullet beside it (OALD's examples, gallery 2026-10-16).
        document.querySelectorAll('ul,ol').forEach(function (list) {
          var kinds = {};
          Array.prototype.forEach.call(list.children, function (li) {
            if (li.tagName !== 'LI' || !li.getClientRects().length) return;
            var ours = /^marker$/.test(li.getAttribute('data-xdict-before') || li.getAttribute('data-xdict-after') || '');
            var b = getComputedStyle(li, '::before').content, ls = getComputedStyle(li);
            var theirs = !ours && ((b !== 'none' && b !== 'normal' && b !== '""') || (ls.display === 'list-item' && ls.listStyleType !== 'none'));
            kinds[ours ? 'xdict' : theirs ? 'dictionary' : 'none'] = true;
          });
          if (!kinds.xdict) return;
          var mixed = !!kinds.dictionary;
          note('listMarkers', !mixed, 1, 'mixed markers in <' + list.tagName.toLowerCase() + (list.className ? '.' + String(list.className).split(' ')[0] : '') + '>');
        });
        // No word is broken inside a table cell (CALD's level table: one letter a line, as `overflow-wrap:anywhere`
        // let the column shrink to one character).
        var cells = document.querySelectorAll('td,th'), seen = 0;
        for (var ci = 0; ci < cells.length && seen < 3000; ci++) {
          if (!cells[ci].getClientRects().length) continue;
          var tw = document.createTreeWalker(cells[ci], NodeFilter.SHOW_TEXT);
          for (var tn = tw.nextNode(); tn && seen < 3000; tn = tw.nextNode()) {
            var re = /[^\s\-‐]{2,}/g, mm;   // a break at a hyphen is a break between words
            while ((mm = re.exec(tn.nodeValue)) && seen < 3000) {
              seen += 1;
              var wr = document.createRange(); wr.setStart(tn, mm.index); wr.setEnd(tn, mm.index + mm[0].length);
              var tops = {};
              Array.prototype.forEach.call(wr.getClientRects(), function (q) { if (q.width > 0) tops[Math.round(q.top)] = 1; });
              var lines = Object.keys(tops).length;
              note('cellWords', lines <= 1, 1, mm[0].slice(0, 20) + ' over ' + lines + ' lines');
            }
          }
        }
        // Punctuation alone on a line, and gaps wider than 1em between words on one line (OED's "," between its
        // pronunciations; "banc   bench").
        // The line a text is laid out in: its nearest ancestor that is not plain inline (an inline-block is a box of
        // its own: ETYM's fixed-width navigation items). A text inside a float, a positioned box, a flex or grid item
        // or a table cell is out of the line's flow.
        function flow(e) {
          var out = false;
          for (; e && e !== document.body; e = e.parentElement) {
            var st = getComputedStyle(e), d = st.display;
            if (st.float !== 'none' || st.position === 'absolute' || st.position === 'fixed') out = true;
            var up = e.parentElement ? getComputedStyle(e.parentElement).display : 'block';
            if (/flex|grid/.test(up) || d === 'table-cell') out = true;
            if (d !== 'inline' && d !== 'contents') break;
          }
          return { ctx: e, out: out };
        }
        var texts = [], tw2 = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
        for (var t2 = tw2.nextNode(); t2 && texts.length < 20000; t2 = tw2.nextNode()) {
          if (!t2.nodeValue.trim() || !t2.parentElement) continue;
          if (t2.parentElement.closest('[data-xdict-control],[data-xdict-tag],td,th,svg')) continue;
          var r2 = document.createRange(); r2.selectNodeContents(t2);
          var rs = Array.prototype.filter.call(r2.getClientRects(), function (q) { return q.width > 0; });
          if (rs.length) {
            var f2 = flow(t2.parentElement);
            texts.push({ n: t2, first: rs[0], last: rs[rs.length - 1], ctx: f2.ctx, out: f2.out,
              fs: parseFloat(getComputedStyle(t2.parentElement).fontSize) });
          }
        }
        // What draws between two words without being text: XDict's controls, icons, tags, images. Not a label: its
        // words are measured as words, and its box's padding and margin are spacing (OALECD's "especially US    ˌ…").
        var boxes = Array.prototype.map.call(document.querySelectorAll('[data-xdict-control],[data-xdict-icon],[data-xdict-tag],img,svg'),
          function (e) { return e.getBoundingClientRect(); }).filter(function (q) { return q.width > 0; });
        // And the dictionary's own drawings beside a word: generated content (OCD's "→", its "|") and side borders.
        var edges = [], all2 = document.body ? document.body.getElementsByTagName('*') : [];
        for (var i2 = 0; i2 < all2.length && i2 < 20000; i2++) {
          var e2 = all2[i2], st2 = getComputedStyle(e2);
          var drawn2 = parseFloat(st2.borderLeftWidth) > 0 || parseFloat(st2.borderRightWidth) > 0
            || ['::before', '::after'].some(function (p) { var ps = getComputedStyle(e2, p), c = ps.content;
              // Text, or an empty box with a size (XDict's "→" lookup sign is a mask on an empty box).
              return c && c !== 'none' && c !== 'normal' && (c !== '""' || parseFloat(ps.width) > 0); });
          if (!drawn2) continue;
          Array.prototype.forEach.call(e2.getClientRects(), function (q) { if (q.width > 0) edges.push(q); });
        }
        // The widest stretch of the gap between two words that nothing draws in: a box drawn inside it (a tag, an
        // icon, a control) or a drawing's box reaching into it (generated content) covers its part; the space left
        // over is what the text's layout puts there (a label's own box is its text's, and covers none of the gap).
        function uncovered(a, b) {
          var line = function (q) { return q.bottom > a.top && q.top < a.bottom; };
          var inGap = function (v) { return v > a.right - 1 && v < b.left + 1; };
          var spans = [];
          boxes.forEach(function (q) { if (line(q) && Math.min(q.right, b.left) - Math.max(q.left, a.right) > 2) spans.push(q); });
          edges.forEach(function (q) { if (line(q) && (inGap(q.left) || inGap(q.right))) spans.push(q); });
          spans = spans.map(function (q) { return [Math.max(q.left, a.right), Math.min(q.right, b.left)]; })
            .sort(function (p, q) { return p[0] - q[0]; });
          var at = a.right, widest = 0;
          spans.forEach(function (sp) { if (sp[0] > at) widest = Math.max(widest, sp[0] - at); at = Math.max(at, sp[1]); });
          return Math.max(widest, b.left - at);
        }
        // Inside one text: a run of space holding a no-break space does not collapse, and draws as wide as it is written.
        texts.forEach(function (x) {
          var v = x.n.nodeValue, re = /\S([ \t\n ]* [ \t\n ]*)(?=\S)/g, m;
          while ((m = re.exec(v))) {
            var rr = document.createRange(); rr.setStart(x.n, m.index + 1); rr.setEnd(x.n, m.index + 1 + m[1].length);
            var w = 0; Array.prototype.forEach.call(rr.getClientRects(), function (q) { w = Math.max(w, q.width); });
            note('wordGap', w <= x.fs + 0.5, 1, Math.round(w) + 'px of space in ' + JSON.stringify(v.trim().slice(0, 16)));
          }
        });
        texts.forEach(function (x, k) {
          var prev = texts[k - 1], next = texts[k + 1];
          // One line: the two boxes overlap over most of the shorter one's height (faces and sizes differ in a line).
          var same = function (a, b) {
            if (!a || !b) return false;
            var overlap = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
            return overlap > 0.5 * Math.min(a.height, b.height);
          };
          // A separator row of bullets or stars is a line of its own by design.
          // A headword that is punctuation ("@", "&") is the entry's own line.
          if (/^[\s\p{P}\p{S}]+$/u.test(x.n.nodeValue) && !/^[\s•·*⁂‧∙]+$/.test(x.n.nodeValue)
              && !x.n.parentElement.closest('[data-xdict-lead],[data-xdict-role=headword]')) {
            var alone = !same(prev && prev.last, x.first) && !same(x.last, next && next.first);
            note('punctLine', !alone, 1, JSON.stringify(x.n.nodeValue.trim()) + ' alone on a line');
          }
          // A gap between words is measured only inside one line box: one formatting context, neither word floated
          // or positioned (a float, a cell or a right-aligned button beside a line is not a gap in it).
          if (prev && prev.ctx === x.ctx && !prev.out && !x.out && same(prev.last, x.first)
              && x.first.left > prev.last.right) {
            // A field's set-off by its own margin (MW's "/pron/   adjective") counts: R puts inline spacing on the
            // space tokens (coordinator, 2026-10-16).
            var gap = uncovered(prev.last, x.first);
            // For diagnosis, what sets the two words apart: each box up to the line's, with its display and side spacing.
            var why = function (n, side) {
              var out = [];
              for (var e = n.parentElement; e && e !== x.ctx && out.length < 4; e = e.parentElement) {
                var st = getComputedStyle(e);
                out.push(e.tagName.toLowerCase() + ' ' + st.display + ' m' + st['margin' + side] + ' p' + st['padding' + side]
                  + (st.width !== 'auto' && st.display !== 'inline' ? ' w' + st.width : ''));
              }
              return out.join(' < ');
            };
            note('wordGap', gap <= Math.max(x.fs, prev.fs) + 0.5, 1, Math.round(gap) + 'px before ' + JSON.stringify(x.n.nodeValue.trim().slice(0, 16))
              + (gap > Math.max(x.fs, prev.fs) + 0.5 ? ' [after ' + JSON.stringify(prev.n.nodeValue.slice(-6)) + ': ' + why(prev.n, 'Right')
                 + ' | ' + why(x.n, 'Left') + ']' : ''));
          }
        });
        Object.keys(checks).forEach(function (k) {
          var c = checks[k];
          c.values = Object.keys(c.values).sort(function (a, b) { return c.values[b] - c.values[a]; })
            .map(function (v) { return [v, c.values[v]]; });
        });
        return checks;
        """#

    /// Lab only: `XDICT_LAB_ACCENT=<light>,<dark>` renders the gallery with another accent, for the owner to choose
    /// between candidates side by side. A sheet after the frame's, with a more specific selector.
    static var accentCandidate: String? {
        guard let value = ProcessInfo.processInfo.environment["XDICT_LAB_ACCENT"] else { return nil }
        let parts = value.split(separator: ",").map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil })
        else { return nil }
        let css = ":root:root[data-xdict-theme=light]{--xdict-accent:\(parts[0])}"
            + ":root:root[data-xdict-theme=dark]{--xdict-accent:\(parts[1])}"
        return "var s = document.createElement('style'); s.id = 'xdict-lab-accent'; s.textContent = '\(css)';"
            + "(document.head || document.documentElement).appendChild(s); return {};"
    }

    /// Lab only: `XDICT_LAB_CONTROL=1` writes a known fault into every framed page before it is measured, the
    /// positive control of the spacing checks: gaps of no-break spaces inside one text and between two (`wordGap`) and a comma
    /// alone between two blocks (`punctLine`). A run with it must be red.
    static var positiveControl: String? {
        guard ProcessInfo.processInfo.environment["XDICT_LAB_CONTROL"] == "1" else { return nil }
        return "var d = document.createElement('div'); d.innerHTML = '<p>control\\u00a0\\u00a0\\u00a0\\u00a0\\u00a0gap</p>"
            + "<p>split <span>\\u00a0\\u00a0\\u00a0\\u00a0\\u00a0\\u00a0</span> gap</p>"
            + "<div>one</div>,<div>two</div>'; (document.body || document.documentElement).appendChild(d); return {};"
    }

    /// Each invariant broken on this page, as a failure line naming every value off.
    static func invariantFailures(_ checks: [String: Any]?, where place: String) -> [String] {
        guard let checks else { return ["\(place): the invariants were not measured"] }
        return checks.keys.sorted().compactMap { name in
            guard let c = checks[name] as? [String: Any], let off = c["off"] as? Int, off > 0 else { return nil }
            let total = c["total"] as? Int ?? 0
            let values = (c["values"] as? [[Any]] ?? []).map { "\($0.first ?? "?") ×\($0.last ?? "?")" }
            return "\(place): R invariant \(name) off for \(off) of \(total): \(values.joined(separator: "; "))"
        }
    }
}

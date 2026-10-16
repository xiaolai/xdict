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
            note('phonFace', /^"?(Charis|Doulos|Gentium)/.test(cs.fontFamily), k, cs.fontFamily.split(',')[0] + ' <' + label + '>');
          }
          note('colour', !!allowed[cs.color], k, cs.color + ' <' + label + '>');
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
            var re = /\S{2,}/g, mm;
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
        var texts = [], tw2 = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
        for (var t2 = tw2.nextNode(); t2 && texts.length < 20000; t2 = tw2.nextNode()) {
          if (!t2.nodeValue.trim() || !t2.parentElement) continue;
          if (t2.parentElement.closest('[data-xdict-control],[data-xdict-tag],td,th,svg')) continue;
          var r2 = document.createRange(); r2.selectNodeContents(t2);
          var rs = Array.prototype.filter.call(r2.getClientRects(), function (q) { return q.width > 0; });
          if (rs.length) texts.push({ n: t2, first: rs[0], last: rs[rs.length - 1], fs: parseFloat(getComputedStyle(t2.parentElement).fontSize) });
        }
        texts.forEach(function (x, k) {
          var prev = texts[k - 1], next = texts[k + 1];
          var same = function (a, b) { return a && b && Math.abs(a.top - b.top) < 2 && Math.abs(a.bottom - b.bottom) < 2; };
          if (/^[\s\p{P}]+$/u.test(x.n.nodeValue)) {
            var alone = !same(prev && prev.last, x.first) && !same(x.last, next && next.first);
            note('punctLine', !alone, 1, JSON.stringify(x.n.nodeValue.trim()) + ' alone on a line');
          }
          if (prev && same(prev.last, x.first) && x.first.left > prev.last.right) {
            var gap = x.first.left - prev.last.right;
            note('wordGap', gap <= x.fs + 0.5, 1, Math.round(gap) + 'px before ' + JSON.stringify(x.n.nodeValue.trim().slice(0, 16)));
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

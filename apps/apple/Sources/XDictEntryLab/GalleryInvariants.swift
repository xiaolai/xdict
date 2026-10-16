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
        var checks = { size: {}, leading: {}, margin: {}, phonFace: {}, colour: {} };
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
        }
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
        Object.keys(checks).forEach(function (k) {
          var c = checks[k];
          c.values = Object.keys(c.values).sort(function (a, b) { return c.values[b] - c.values[a]; })
            .map(function (v) { return [v, c.values[v]]; });
        });
        return checks;
        """#

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

import Foundation

/// **The gallery's checks G1–G15** (`dev-docs/reading-style.md` §7.2), on a framed page in the reading style, each
/// computed in the page from `getComputedStyle` and geometry and reported as characters or elements checked, those
/// off, and the values off. The run's failures name every check off. `XDICT_LAB_CONTROL=G` writes one known fault for
/// each check into every page first, their positive control: a run with it must be red in all fifteen.
///
/// Where §7.2 asks for what one framed page cannot show, the check says so in its `note` and measures the rest:
/// G4's inset at 320 px and characters per line at 820 px are measured only at those widths; G8's layout-table
/// positions and G9's clipped boxes need the "before" view (normalization off), which this tree's lab does not
/// render; G11's accent tags against the census and G12's `lang` are recorded, not failed.
extension GalleryRun {
    static let checksScript = #"""
        var G = {};
        for (var g = 1; g <= 15; g++) G['G' + g] = { total: 0, off: 0, values: {}, note: '' };
        function note(k, ok, n, value) {
          var c = G[k]; c.total += n;
          if (!ok) { c.off += n; c.values[value] = (c.values[value] || 0) + n; }
        }
        var root = document.documentElement, body = document.body || root;
        var dark = root.getAttribute('data-xdict-theme') === 'dark';
        function seen(e) { return e && e.getClientRects().length > 0; }
        function label(e) { return e.tagName.toLowerCase() + (e.className && typeof e.className === 'string' ? '.' + e.className.split(' ')[0] : ''); }
        function rgba(s) { var m = /rgba?\(([^)]*)\)/.exec(s || ''); if (!m) return null;
          var v = m[1].split(/[,\s\/]+/).filter(Boolean).map(parseFloat); return [v[0], v[1], v[2], v.length > 3 ? v[3] : 1]; }
        function lin(u) { u /= 255; return u <= 0.04045 ? u / 12.92 : Math.pow((u + 0.055) / 1.055, 2.4); }
        function lum(c) { return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2]); }
        function lstar(c) { var y = lum(c); return (y > 216 / 24389 ? Math.cbrt(y) * 116 - 16 : y * 24389 / 27) / 100; }
        function over(top, under) { var a = top[3]; return [0, 1, 2].map(function (i) { return top[i] * a + under[i] * (1 - a); }).concat([1]); }
        // Tokens, as computed values in this theme.
        var probe = document.createElement('span'); body.appendChild(probe);
        function token(name, prop) { probe.style[prop] = 'var(--xdict-' + name + ')'; var v = getComputedStyle(probe)[prop]; probe.style[prop] = ''; return v; }
        var NAMES = ['bg', 'panel', 'text', 'text-2', 'rule', 'plate', 'accent', 'link', 'phon-colour'];
        ['red', 'orange', 'yellow', 'green', 'teal', 'blue', 'purple', 'pink'].forEach(function (h) { NAMES.push(h + '-deep', h, h + '-tint'); });
        var colours = {}, backs = {};
        NAMES.forEach(function (n) { colours[token(n, 'color')] = n; backs[token(n, 'backgroundColor')] = n; });
        var BG = rgba(token('bg', 'backgroundColor')), TEXT2 = token('text-2', 'color'), PLATE = token('plate', 'backgroundColor');
        var FACES = {};
        ['font', 'font-phon', 'font-text'].forEach(function (n) {
          var f = token(n, 'fontFamily'); if (f) FACES[f.split(',')[0].replace(/["']/g, '').trim()] = n;
        });
        probe.remove();
        var base = parseFloat(getComputedStyle(root).fontSize);
        var bodyCS = getComputedStyle(body), bodyR = body.getBoundingClientRect();
        var padL = parseFloat(bodyCS.paddingLeft), padR = parseFloat(bodyCS.paddingRight);
        var col = { left: bodyR.left + padL, right: bodyR.right - padR };
        function effectiveBg(e) {
          var layers = [];
          for (; e; e = e.parentElement) { var c = rgba(getComputedStyle(e).backgroundColor); if (c && c[3] > 0) { layers.push(c); if (c[3] >= 1) break; } }
          var out = BG; for (var i = layers.length - 1; i >= 0; i--) out = over(layers[i], out);
          return out;
        }
        // Text: G1, G2, G3, G6, G12, G13.
        var RATIOS = [0.75, 0.875, 1, 1.125, 1.25, 1.5], bySize = {}, chars = 0;
        var w = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
        for (var n = w.nextNode(); n; n = w.nextNode()) {
          var t = n.nodeValue.replace(/\s+/g, ''), el = n.parentElement;
          if (!t.length || !el || el.closest('svg,[data-xdict-icon]')) continue;
          var r = document.createRange(); r.selectNodeContents(n);
          if (!r.getClientRects().length) continue;
          var cs = getComputedStyle(el), fs = parseFloat(cs.fontSize), k = t.length, lb = label(el);
          if (cs.visibility === 'hidden' || /^rgba\(.*,\s*0\)$/.test(cs.color)) continue;
          chars += k; bySize[Math.round(fs * 2) / 2] = (bySize[Math.round(fs * 2) / 2] || 0) + k;
          var ratio = fs / base, onScale = RATIOS.some(function (s) { return Math.abs(ratio - s) <= 0.01; });
          note('G1', onScale && fs >= 11.5 && fs <= 24.5, k, Math.round(fs * 10) / 10 + 'px <' + lb + '>');
          var lh = cs.lineHeight === 'normal' ? NaN : parseFloat(cs.lineHeight) / fs, want = fs >= 19.5 ? 1.3 : 1.6;
          note('G3', Math.abs(lh - want) <= 0.05, k, (isNaN(lh) ? 'normal' : Math.round(lh * 100) / 100) + ' at ' + Math.round(fs) + 'px <' + lb + '>');
          var fg = rgba(cs.color), bg = effectiveBg(el);
          if (fg) {
            var a = lum(over(fg, bg)), b = lum(bg), ratioC = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
            var need = fs >= 19.5 ? 3 : 4.5;
            note('G6', ratioC >= need - 0.005, k, 'contrast ' + Math.round(ratioC * 100) / 100 + ' ' + cs.color + ' <' + lb + '>');
            note('G6', !!colours[cs.color], k, 'text colour ' + cs.color + ' not a token <' + lb + '>');
          }
          if (/[㐀-鿿豈-﫿]/.test(n.nodeValue)) {
            var slanted = cs.fontStyle !== 'normal' && cs.fontSynthesisStyle !== 'none';
            note('G12', !slanted, k, 'Han slanted (' + cs.fontStyle + ', synthesis ' + cs.fontSynthesisStyle + ') <' + lb + '>');
          }
          var face = cs.fontFamily.split(',')[0].replace(/["']/g, '').trim();
          var kept = el.closest('[data-xdict-tag],[data-xdict-control]') || /^font:/.test((el.closest('[data-xdict-phon]') || el).getAttribute('data-xdict-phon-system') || '');
          note('G13', !!FACES[face] || !!kept, k, face + ' <' + lb + '>');
        }
        // G2 is the dictionary's: the page gives its characters by size, and the run takes the dominant size of all a
        // dictionary's pages in a theme (`dominantSizeFailures`).
        G.G2.sizes = bySize;
        // G12's records: `lang` and text-autospace.
        var hanNoLang = Array.prototype.filter.call(body.querySelectorAll('*'), function (e) {
          return /[㐀-鿿]/.test(Array.prototype.map.call(e.childNodes, function (c) { return c.nodeType === 3 ? c.nodeValue : ''; }).join('')) && !e.closest('[lang]');
        }).length;
        G.G12.note = 'Han runs without lang: ' + hanNoLang + '; text-autospace ' + (CSS.supports('text-autospace', 'normal') ? 'supported' : 'unsupported');
        // G4: the column.
        var measure = parseFloat(getComputedStyle(root).getPropertyValue('--xdict-measure')) * (/rem|em/.test(getComputedStyle(root).getPropertyValue('--xdict-measure')) ? base : 1);
        var content = col.right - col.left;
        if (!isNaN(measure)) note('G4', content <= measure + 0.5, 1, 'column ' + Math.round(content) + 'px over measure ' + Math.round(measure) + 'px');
        if (innerWidth <= 330) note('G4', col.left >= 11.5, 1, 'left inset ' + Math.round(col.left) + 'px at ' + innerWidth);
        if (innerWidth >= 800 && innerWidth <= 840) {
          var al = document.createElement('span'); al.textContent = 'abcdefghijklmnopqrstuvwxyz'; al.style.whiteSpace = 'nowrap';
          body.appendChild(al); var cw = al.getBoundingClientRect().width / 26; al.remove();
          var cpl = content / cw;
          note('G4', cpl >= 55 && cpl <= 85, 1, Math.round(cpl) + ' characters per line at ' + innerWidth + 'px');
        } else G.G4.note = 'characters per line measured at 820px only';
        // Elements: G5, G7, G10, G15.
        var all = body.getElementsByTagName('*');
        for (var i = 0; i < all.length && i < 30000; i++) {
          var e = all[i];
          if (!seen(e) || e.closest('svg') && e.tagName.toLowerCase() !== 'svg') continue;
          var es = getComputedStyle(e), er = e.getBoundingClientRect();
          if (es.visibility === 'hidden') continue;
          // G5: no visible border, but a shape drawn with borders (a zero-width or zero-height box with a transparent side).
          var sides = ['Top', 'Right', 'Bottom', 'Left'].filter(function (s) {
            var c = rgba(es['border' + s + 'Color']);
            return parseFloat(es['border' + s + 'Width']) > 0 && !/none|hidden/.test(es['border' + s + 'Style']) && c && c[3] > 0;
          });
          if (sides.length) {
            var shape = (e.clientWidth === 0 || e.clientHeight === 0) && ['Top', 'Right', 'Bottom', 'Left'].some(function (s) {
              var c = rgba(es['border' + s + 'Color']); return parseFloat(es['border' + s + 'Width']) > 0 && c && c[3] === 0; });
            note('G5', shape, 1, sides.join('/') + ' ' + es.borderTopWidth + ' ' + es.borderTopStyle + ' <' + label(e) + '>');
          } else note('G5', true, 1, '');
          // G6: a background is a token.
          var bc = rgba(es.backgroundColor), media = /^(img|svg|video|canvas|picture)$/i.test(e.tagName);
          if (bc && bc[3] > 0 && !media) note('G6', !!backs[es.backgroundColor], 1, 'background ' + es.backgroundColor + ' not a token <' + label(e) + '>');
          // G7: no light block in dark, but images and plates.
          if (dark && bc && bc[3] >= 0.5 && !media && es.backgroundColor !== PLATE) {
            note('G7', lstar(over(bc, BG)) < 0.8, 1, 'L ' + Math.round(lstar(over(bc, BG)) * 100) / 100 + ' ' + es.backgroundColor + ' <' + label(e) + '>');
          }
          // G10: a fixed box inside body's; nothing painted outside the column's padding box (but in a scroller).
          if (es.position === 'fixed') note('G10', er.left >= bodyR.left - 1 && er.right <= bodyR.right + 1 && er.top >= bodyR.top - 1, 1, 'fixed <' + label(e) + '>');
          var clipped = false;
          for (var p = e.parentElement; p && p !== body; p = p.parentElement) { if (getComputedStyle(p).overflowX !== 'visible') { clipped = true; break; } }
          if (!clipped && er.width > 0) note('G10', er.left >= bodyR.left - 1 && er.right <= bodyR.right + 1, 1, 'painted outside the column ' + Math.round(er.left) + '…' + Math.round(er.right) + ' <' + label(e) + '>');
          // G15: images.
          if (/^(img|svg)$/i.test(e.tagName) && !e.closest('[data-xdict-icon]')) {
            var box = e.parentElement ? e.parentElement.getBoundingClientRect() : bodyR;
            note('G15', er.width <= Math.max(box.width, content) + 1, 1, 'image ' + Math.round(er.width) + 'px wide in ' + Math.round(box.width) + ' <' + label(e) + '>');
            var nh = e.naturalHeight || er.height, em = parseFloat(getComputedStyle(e.parentElement || body).fontSize);
            if (nh <= 48) note('G15', er.height <= 1.25 * em + 0.5, 1, 'small image ' + Math.round(er.height) + 'px tall at ' + em + 'px <' + label(e) + '>');
            var src = (e.currentSrc || e.getAttribute('src') || '').toLowerCase();
            if (dark && e.tagName.toLowerCase() === 'img' && nh > 48 && /\.(png|gif|svg)(\?|#|$)|^data:image\/(png|gif|svg)/.test(src)) {
              note('G15', es.backgroundColor === PLATE, 1, 'illustration without the plate in dark ' + es.backgroundColor + ' <' + label(e) + '>');
            }
          }
        }
        // G8: no horizontal overflow; a data table fits, or scrolls inside its own box.
        note('G8', root.scrollWidth <= root.clientWidth + 1, 1, 'page overflows: ' + root.scrollWidth + ' > ' + root.clientWidth);
        body.querySelectorAll('table[data-xdict-table=data]').forEach(function (tb) {
          if (!seen(tb)) return;
          var tr = tb.getBoundingClientRect(), fits = tr.right <= col.right + 1 && tr.left >= col.left - 1;
          var scroller = tb.closest('[data-xdict-scroll]') || (/auto|scroll/.test(getComputedStyle(tb).overflowX) ? tb : null);
          note('G8', fits || !!scroller, 1, 'data table ' + Math.round(tr.width) + 'px, no scroller <' + label(tb) + '>');
        });
        G.G8.note = 'layout-table positions against before: needs the before view';
        // G11: controls.
        body.querySelectorAll('[data-xdict-control=speaker]').forEach(function (sp) {
          if (!seen(sp)) return;
          var icons = Array.prototype.filter.call(sp.querySelectorAll('[data-xdict-icon=speaker]'), seen);
          var other = Array.prototype.filter.call(sp.querySelectorAll('img,svg'), function (x) { return seen(x) && !x.closest('[data-xdict-icon]'); });
          note('G11', icons.length === 1 && other.length === 0, 1, icons.length + ' speaker icons, ' + other.length + ' other images <' + label(sp) + '>');
          var hr = sp.getBoundingClientRect();
          note('G11', hr.width >= 23.5 && hr.height >= 23.5, 1, 'hit box ' + Math.round(hr.width) + '×' + Math.round(hr.height) + ' <' + label(sp) + '>');
          if (icons[0]) note('G11', getComputedStyle(icons[0]).color === getComputedStyle(sp).color, 1, 'glyph ' + getComputedStyle(icons[0]).color + ' vs ' + getComputedStyle(sp).color);
        });
        G.G11.note = 'accent tags against the census: not measured here';
        // G14: each level of a list starts one indent (1.5em of the list) inside the content box it sits in, so a list
        // at depth n starts n indents in; XDict's marker gutter is the item's own, inside its content. A list laid out
        // as a row (flex, grid, inline) is not a column of items and has no indent. XDict's markers are text-2.
        body.querySelectorAll('ul,ol').forEach(function (l) {
          if (!seen(l) || l.closest('[data-xdict-control]') || !l.parentElement) return;
          var ls = getComputedStyle(l);
          if (!/^(block|list-item)$/.test(ls.display)) return;
          var ps = getComputedStyle(l.parentElement), pr = l.parentElement.getBoundingClientRect();
          var rtl = ls.direction === 'rtl', lr = l.getBoundingClientRect();
          var start = rtl ? pr.right - parseFloat(ps.paddingRight) - parseFloat(ps.borderRightWidth)
                          : pr.left + parseFloat(ps.paddingLeft) + parseFloat(ps.borderLeftWidth);
          var inner = rtl ? lr.right - parseFloat(ls.paddingRight) - parseFloat(ls.borderRightWidth)
                          : lr.left + parseFloat(ls.paddingLeft) + parseFloat(ls.borderLeftWidth);
          var inset = rtl ? start - inner : inner - start, want = 1.5 * parseFloat(ls.fontSize);
          note('G14', Math.abs(inset - want) <= 1, 1, 'inset ' + Math.round(inset) + 'px, want ' + Math.round(want) + ' <' + label(l) + '>');
        });
        body.querySelectorAll('[data-xdict-before=marker],[data-xdict-after=marker]').forEach(function (m) {
          if (!seen(m)) return;
          var ps = getComputedStyle(m, m.getAttribute('data-xdict-before') === 'marker' ? '::before' : '::after');
          if (ps.content === 'none' || ps.display === 'none') return;
          note('G14', ps.backgroundColor === TEXT2, 1, 'marker ' + ps.backgroundColor + ' <' + label(m) + '>');
        });
        // G9: every fold head opens and closes its fold, and is left as it was. Last: it clicks the page.
        // A head's fold is the one the frame syncs it with (disclosure-core.js): `aria-controls`, else the next sibling
        // of the head or of one of its three nearest ancestors.
        function foldOf(c) {
          var id = c.getAttribute('aria-controls'), named = id && document.getElementById(id);
          if (named) return named;
          for (var e = c, up = 0; e && up < 3; e = e.parentElement, up++) if (e.nextElementSibling) return e.nextElementSibling;
          return null;
        }
        var heads = Array.prototype.filter.call(body.querySelectorAll('[data-xdict-control=disclosure]'), seen).slice(0, 8);
        function shown(x) { return !!x && x.checkVisibility({ visibilityProperty: true }) && x.getBoundingClientRect().height > 0; }
        for (var h = 0; h < heads.length; h++) {
          var head = heads[h], target = foldOf(head);
          // Opened and closed, as §7.2 measures it: the fold's visibility, or the height of the head with its fold
          // (a head that holds its own fold and toggles a class on itself: COBUILD's "Trends"). The chevron's state
          // is the marks check's (`foldMismatch`).
          var box = function () { return head.getBoundingClientRect().height + (target ? target.getBoundingClientRect().height : 0); };
          // Settled: the same height twice 100 ms apart (a fold that animates, COBUILD's), at most 2 s.
          var settle = async function () {
            var last = -1;
            for (var k = 0; k < 20; k++) {
              await new Promise(function (res) { setTimeout(res, 100); });
              var now = box(); if (Math.abs(now - last) < 0.5) return; last = now;
            }
          };
          var v0 = shown(target), h0 = box();
          head.click(); await settle();
          var v1 = shown(target), h1 = box();
          head.click(); await settle();
          var v2 = shown(target), h2 = box();
          // Back the way it came: the same visibility, the height moving back past the first click's (a chart drawn
          // again on opening need not be the same height to the pixel).
          var moved = (v1 !== v0 || Math.abs(h1 - h0) > 1) && v2 === v0
            && (v1 !== v0 || (Math.sign(h2 - h1) === Math.sign(h0 - h1) && Math.abs(h2 - h1) > 1));
          note('G9', moved, 1, 'fold ' + (head.textContent || '').trim().slice(0, 24) + ' ' + v0 + '→' + v1 + '→' + v2 + ' ' + Math.round(h0) + '→' + Math.round(h1) + '→' + Math.round(h2));
        }
        G.G9.note = 'clipped overflow boxes against before: needs the before view';
        Object.keys(G).forEach(function (k) {
          var c = G[k];
          c.values = Object.keys(c.values).sort(function (a, b) { return c.values[b] - c.values[a]; }).slice(0, 12)
            .map(function (v) { return [v, c.values[v]]; });
        });
        return G;
        """#

    /// `XDICT_LAB_CONTROL=G`: one known fault for each of G1–G15, written into the page before it is measured.
    static var checksControl: String? {
        guard ProcessInfo.processInfo.environment["XDICT_LAB_CONTROL"] == "G" else { return nil }
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let faults = [
            "<p style='font-size:11px'>G1 eleven pixels</p>",
            "<div style='font-size:13px !important'>" + String(repeating: "G2 dominant thirteen ", count: 400) + "</div>",
            "<p style='line-height:1 !important'>G3 tight leading</p>",
            // A sheet, not inline styles: the colour guard maps inline colours and borders to tokens.
            "<style>#g5c{border:2px solid #000 !important}#g6c{color:#fefefe !important}"
                + "#g7c{background:#ffffff !important;color:#000 !important}</style>",
            "<p id='g5c'>G5 a border</p><p id='g6c'>G6 faint</p><p id='g7c'>G7 a light block</p>",
            "<table data-xdict-table='data' style='display:table !important;width:3000px'><tr><td>G8</td></tr></table>",
            "<a data-xdict-control='disclosure' aria-expanded='false' aria-controls='g9fold'>G9 head</a><div id='g9fold'>never folds</div>",
            "<div style='position:fixed !important;left:-200px;top:0'>G10 outside</div>",
            "<a data-xdict-control='speaker' href='sound://g11.mp3'><img src='\(png)' width='8' height='8'></a>",
            "<i style='font-synthesis:style !important;font-style:italic !important'>G12 汉字</i>",
            "<p style='font-family:Courier !important'>G13 another face</p>",
            "<ul style='padding-left:100px !important;margin-left:0 !important'><li>G14 deep</li></ul>",
            "<img src='\(png)' style='width:3000px !important;max-width:none !important;height:4px'>",
        ]
        let html = faults.joined().replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // G4: the column wider than the measure. G7 shows only in a dark run.
        return "var d = document.createElement('div'); d.innerHTML = \"\(html)\";"
            + "var b = document.body || document.documentElement; b.appendChild(d);"
            + "b.style.setProperty('max-width', '4000px', 'important'); return {};"
    }

    /// G2: the dominant size (most characters) of each dictionary's pages, per theme, is 16 px ± 0.5.
    static func dominantSizeFailures(_ rows: [[String: Any]]) -> [String] {
        var sizes: [String: [Double: Int]] = [:]
        for row in rows {
            guard let dict = row["dict"] as? String, let mode = row["mode"] as? String,
                  let checks = row["checks"] as? [String: Any], let g2 = checks["G2"] as? [String: Any],
                  let page = g2["sizes"] as? [String: Any] else { continue }
            let key = "\(dict) \(mode.hasSuffix("dark") ? "dark" : "light")"
            for (size, count) in page {
                if let px = Double(size), let n = (count as? NSNumber)?.intValue { sizes[key, default: [:]][px, default: 0] += n }
            }
        }
        return sizes.keys.sorted().compactMap { key in
            guard let (px, n) = sizes[key]?.max(by: { $0.value < $1.value }), abs(px - 16) > 0.5 else { return nil }
            let all = sizes[key]?.values.reduce(0, +) ?? 0
            return "\(key): G2 the dominant size is \(px)px (\(n) of \(all) characters)"
        }
    }

    /// Each check off on this page, as a failure line naming its values.
    static func checkFailures(_ checks: [String: Any]?, where place: String) -> [String] {
        guard let checks else { return ["\(place): G1–G15 were not measured"] }
        // G2 is per dictionary (`dominantSizeFailures`).
        return (1...15).filter { $0 != 2 }.compactMap { index in
            let name = "G\(index)"
            guard let c = checks[name] as? [String: Any] else { return "\(place): \(name) missing" }
            guard let off = c["off"] as? Int, off > 0 else { return nil }
            let total = c["total"] as? Int ?? 0
            let values = (c["values"] as? [[Any]] ?? []).map { "\($0.first ?? "?") ×\($0.last ?? "?")" }
            return "\(place): \(name) off for \(off) of \(total): \(values.joined(separator: "; "))"
        }
    }
}

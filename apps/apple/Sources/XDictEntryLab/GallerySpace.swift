import AppKit
import Foundation
import WebKit

/// **G16 and G17** (`dev-docs/reading-style.md` §7.2; WI-11, 2026-10-17): spacing by role and image placement, measured
/// at several widths of the same page (G16 at 480 and 820 px, G17 at 320, 480, 820 and 1,280), after the other checks.
/// Written apart from the frame's own code (`frame.js` `roleSpace`, `images`): only the role-to-token table and the
/// image classes are shared definitions. `XDICT_LAB_CONTROL=G` writes their faults just before they measure, after the
/// fold clicks, so the frame does not space them again: an example with a 40 px margin (G16 red for `example` only)
/// and a 600 × 600 image with no margin, pulled over the line before it (G17 red for size, space and overlap).
/// `XDICT_LAB_DENSITY=panel` renders the lookup panel's density instead of the main window's.
extension GalleryRun {
    static let spaceWidths: [CGFloat] = [320, 360, 480, 820, 1280]

    static func spaceScript(width: CGFloat, control: Bool) -> String {
        "var WIDTH = \(Int(width)), G16ON = \(width == 360 || width == 480 || width == 820), CONTROL = \(control);\n" + spaceChecks
    }

    static let spaceChecks = #"""
        var G = { G16: { total: 0, off: 0, values: {}, inline: 0, first: 0 }, G17: { total: 0, off: 0, values: {} } };
        function note(k, ok, value) { var c = G[k]; c.total += 1; if (!ok) { c.off += 1; c.values[value] = (c.values[value] || 0) + 1; } }
        var body = document.body;
        function label(e) { return e.tagName.toLowerCase() + (e.className && typeof e.className === 'string' ? '.' + e.className.split(' ')[0] : ''); }
        function inl(st) { return st.display === 'inline' || /^inline-/.test(st.display); }
        // Written fresh at each width and measured at once, so no pass of the frame's spaces or classes it.
        var old = document.getElementById('g1617c'); if (old) old.remove();
        if (CONTROL) {
          var c = document.createElement('div'); c.id = 'g1617c';
          c.innerHTML = "<p>G16 a line</p><div data-xdict-role='example' style='margin-top:40px !important'>G16 an example</div>"
            + "<p>G17 text <img style='margin:-30px 0 0 0 !important;max-width:none !important;max-height:none !important' "
            + "src=\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='600' height='600'%3E%3Crect width='600' height='600' fill='%23888'/%3E%3C/svg%3E\"> beside it</p>";
          body.appendChild(c);
          try { await c.querySelector('img').decode(); } catch (err) {}
        }
        var probe = document.createElement('div'); probe.style.cssText = 'position:absolute;visibility:hidden;margin:0;padding:0'; body.appendChild(probe);
        var PX = {};
        ['sense', 'example', 'translation', 'subhead', 'heading', 'phrase', 'pos', 'after-heading', 'image', 'space-1', 'space-4'].forEach(function (n) {
          probe.style.height = 'var(--xdict-' + (/^space-/.test(n) ? n : 'space-' + n) + ')'; PX[n] = parseFloat(getComputedStyle(probe).height) || 0; });
        probe.remove();
        // The role table (`reading-style.md` R7a).
        var ROLE = { sense: 'sense', sensenum: 'sense', example: 'example', 'example-trans': 'translation', trans: 'translation',
                     subhead: 'subhead', heading: 'heading', pos: 'pos' };
        function roleSpace(e) {
          var r = e.getAttribute('data-xdict-role');
          if (r === 'section') return /^(idioms|phrasal|colloc|derivatives)$/.test(e.getAttribute('data-xdict-section') || '') ? 'phrase' : 'heading';
          return ROLE[r] || '';
        }
        function shown(n) {
          if (n.nodeType === 3) { if (!/\S/.test(n.nodeValue)) return false; var r = document.createRange(); r.selectNodeContents(n); return r.getClientRects().length > 0; }
          if (n.nodeType !== 1 || !n.getClientRects().length) return false;
          var s = getComputedStyle(n); return s.float === 'none' && s.position !== 'absolute' && s.position !== 'fixed' && !(block(s) && n.getBoundingClientRect().height === 0);
        }
        function block(s) { return /^(block|list-item|flow-root|table|flex|grid)$/.test(s.display) && s.float === 'none' && s.position !== 'absolute' && s.position !== 'fixed'; }
        // The content before a block: a shown sibling of it, or of an ancestor it is the first content of; none when it
        // is first in the entry, in a box with a top edge or its own formatting context, or in a role block.
        function prev(e) {
          for (var n = e; n && n !== body; n = n.parentElement) {
            for (var s = n.previousSibling; s; s = s.previousSibling) if (shown(s)) return s;
            var p = n.parentElement;
            if (!p || p === body || (p.hasAttribute('data-xdict-role') && roleSpace(p) && block(getComputedStyle(p)))) return null;
            var ps = getComputedStyle(p);
            if (inl(ps)) continue;
            if (!/^(block|list-item)$/.test(ps.display) || ps.overflow !== 'visible' || parseFloat(ps.paddingTop) > 0 || parseFloat(ps.borderTopWidth) > 0) return null;
          }
          return null;
        }
        function next(e) {
          for (var n = e; n && n !== body; n = n.parentElement) {
            for (var s = n.nextSibling; s; s = s.nextSibling) if (shown(s)) return s;
            var ps = getComputedStyle(n.parentElement || body);
            if (n.parentElement === body || (!inl(ps) && (ps.overflow !== 'visible' || parseFloat(ps.paddingBottom) > 0))) return null;
          }
          return null;
        }
        // A line box's edge: the inline content's last (or first) fragment, widened by the half-leading.
        function edge(n, last) {
          var el = n.nodeType === 3 ? n.parentElement : n;
          // An inline box's edge is its content's: around a block it also has empty fragments (PEU's inline items).
          if (n.nodeType === 1 && getComputedStyle(n).display === 'inline') {
            for (var c = last ? n.lastChild : n.firstChild; c; c = last ? c.previousSibling : c.nextSibling) if (shown(c)) return edge(c, last);
          }
          if (n.nodeType === 1 && getComputedStyle(n).display !== 'inline') { var b = n.getBoundingClientRect(); return last ? b.bottom : b.top; }
          var r = document.createRange(); r.selectNodeContents(n); var rs = r.getClientRects();
          if (!rs.length) { var bb = el.getBoundingClientRect(); return last ? bb.bottom : bb.top; }
          var f = Array.prototype.reduce.call(rs, function (x, y) { return y.height > 0 && (last ? y.bottom > x.bottom : y.top < x.top) ? y : x; }, rs[0]), lh = parseFloat(getComputedStyle(el).lineHeight), half = isNaN(lh) ? 0 : Math.max(0, (lh - f.height) / 2);
          return last ? f.bottom + half : f.top - half;
        }
        function afterHeading(p) {
          if (!p || p.nodeType !== 1) return false;
          if (p.getAttribute('data-xdict-role') === 'heading') return true;
          var h = p.querySelector('[data-xdict-role=heading]'); return !!h && h.textContent.trim() === p.textContent.trim();
        }
        // R16's classes, the checker's own copy (the frame's is `XDictFrameCore.imageClass`): for an image the frame
        // left unclassed, so its treatment can still be checked.
        function classOf(f) {
          var w = f.w || 0, h = f.h || 0;
          if (!(w > 0 && h > 0)) return '';
          if (f.table) return 'table';
          if (h <= 64 && w > 48 && w / h >= 2.5) return 'text';
          if (w <= 96 && h <= 48) return f.floated ? 'badge' : 'icon';
          if (f.floated) return 'float';
          return f.text ? 'inline' : 'illustration';
        }
        function blockImage(e) { var i = e.tagName === 'IMG' ? e : e.hasAttribute('data-xdict-img-holder') && !(e.parentElement && e.parentElement.hasAttribute('data-xdict-img-holder')) ? e.querySelector('img[data-xdict-img]') : null; return !!i && /^(illustration|inline|float)$/.test(i.getAttribute('data-xdict-img') || '') && block(getComputedStyle(i)); }
        // G16: every role block that starts a line has its role's gap before it, ± 2 px.
        if (G16ON) {
          body.querySelectorAll('[data-xdict-role]').forEach(function (e) {
            var name = roleSpace(e);
            if (!name || e.closest('[data-xdict-control]') || !e.getClientRects().length) return;
            var st = getComputedStyle(e);
            if (!block(st)) { G.G16.inline += 1; return; }
            var p = prev(e);
            if (!p) { G.G16.first += 1; return; }
            var want = afterHeading(p) ? PX['after-heading'] : PX[name];
            if (p.nodeType === 1 && blockImage(p)) want = Math.max(want, PX.image);
            // A block inside an inline box is spaced by its top padding (WebKit honours no top margin through it): its
            // gap runs to where its content starts.
            var inside = false; for (var ia = e.parentElement; ia && ia !== body; ia = ia.parentElement) if (inl(getComputedStyle(ia))) { inside = true; break; }
            var pad = inside ? parseFloat(st.paddingTop) || 0 : 0;
            var gap = e.getBoundingClientRect().top + pad - edge(p, true);
            note('G16', Math.abs(gap - want) <= 2, name + ' at ' + WIDTH + ': ' + Math.round(gap) + 'px, want ' + Math.round(want) + ' <' + label(e) + '>');
          });
        }
        // G17: images by class.
        var texts = [], w = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
        for (var t = w.nextNode(); t && texts.length < 20000; t = w.nextNode()) {
          if (!/\S/.test(t.nodeValue) || !t.parentElement || getComputedStyle(t.parentElement).visibility === 'hidden') continue;
          var rg = document.createRange(); rg.selectNodeContents(t);
          // Only text that shows: a fragment a clipping box (`overflow` other than visible) cuts away is not text an
          // image can touch (MED's slideshow captions under its 200 px window).
          var clip = null;
          for (var ca = t.parentElement; ca && ca !== body; ca = ca.parentElement) if (getComputedStyle(ca).overflow !== 'visible') { clip = ca.getBoundingClientRect(); break; }
          Array.prototype.forEach.call(rg.getClientRects(), function (q) {
            if (q.width <= 1 || q.height <= 1) return;
            if (clip && (q.right <= clip.left || q.left >= clip.right || q.bottom <= clip.top || q.top >= clip.bottom)) return;
            texts.push(q);
          });
        }
        var dark = document.documentElement.getAttribute('data-xdict-theme') === 'dark';
        var PLATE = (function () { var s = document.createElement('span'); s.style.backgroundColor = 'var(--xdict-plate)'; body.appendChild(s); var v = getComputedStyle(s).backgroundColor; s.remove(); return v; })();
        function transparent(img) {
          try {
            var cv = document.createElement('canvas'); cv.width = Math.min(48, img.naturalWidth); cv.height = Math.min(48, img.naturalHeight);
            var g = cv.getContext('2d'); g.drawImage(img, 0, 0, cv.width, cv.height); var d = g.getImageData(0, 0, cv.width, cv.height).data;
            for (var i = 3; i < d.length; i += 4) if (d[i] < 250) return true;
            return false;
          } catch (err) { return /\.(png|gif|svg)(\?|#|$)|^data:image\/(png|gif|svg)/i.test(img.currentSrc || img.src || ''); }
        }
        Array.prototype.forEach.call(body.getElementsByTagName('img'), function (img) {
          if (/^xdict:\/\/d\/blocked\//.test(img.currentSrc || img.src || '')) return;   // ADR-0009's placeholder
          if (!img.getClientRects().length || !img.complete || !(img.naturalWidth > 0)
              || img.closest('[data-xdict-control],[data-xdict-icon],[data-xdict-labelled]')) return;
          var st = getComputedStyle(img), r = img.getBoundingClientRect(), kind = img.getAttribute('data-xdict-img'), lb = label(img);
          if (st.visibility === 'hidden' || r.width < 1 || r.height < 1) return;
          var em = parseFloat(st.fontSize), where = kind + ' at ' + WIDTH + ' ';
          note('G17', !!kind, 'unclassed ' + img.naturalWidth + '×' + img.naturalHeight + ' <' + lb + '>');
          if (!kind) kind = classOf({ w: img.naturalWidth, h: img.naturalHeight, table: !!img.closest('td,th'), floated: st.float !== 'none', text: inl(st) }); where = kind + ' at ' + WIDTH + ' ';
          var box = img.parentElement.getBoundingClientRect();
          for (var a = img.parentElement; a && inl(getComputedStyle(a)); a = a.parentElement) box = a.parentElement ? a.parentElement.getBoundingClientRect() : box;
          note('G17', r.width <= box.width + 1, where + 'wider than its container ' + Math.round(r.width) + ' > ' + Math.round(box.width) + ' <' + lb + '>');
          // A picture inside the dictionary's own positioned layout (MED's slideshow stacks its slides, R13 keeps
          // positioning) overlaps by design: not a placement fault.
          var placed = false;
          for (var pa = img.parentElement; pa && pa !== body; pa = pa.parentElement) if (/absolute|fixed/.test(getComputedStyle(pa).position)) { placed = true; break; }
          var inset = !placed && texts.some(function (q) { return r.left + 1 < q.right - 1 && r.right - 1 > q.left + 1 && r.top + 1 < q.bottom - 1 && r.bottom - 1 > q.top + 1; });
          note('G17', !inset, where + 'over text <' + lb + '>');
          if (/^(illustration|inline)$/.test(kind) || (kind === 'float' && st.float === 'none')) {
            var lim = 20 * em;
            note('G17', r.width <= lim + 1 && r.height <= lim + 1, where + 'over 20em: ' + Math.round(r.width) + '×' + Math.round(r.height) + ' <' + lb + '>');
            note('G17', block(st), where + 'not a block (' + st.display + ') <' + lb + '>');
            var outer = img; while (outer.parentElement && outer.parentElement.hasAttribute('data-xdict-img-holder')) outer = outer.parentElement;
            var p = prev(outer);
            if (p) { var up = outer.getBoundingClientRect().top - edge(p, true); note('G17', Math.abs(up - PX.image) <= 2, where + 'space above ' + Math.round(up) + ', want ' + Math.round(PX.image) + ' after ' + (p.nodeType === 3 ? 'text' : label(p)) + ' (spaced ' + (outer.getAttribute('data-xdict-space') || 'no') + ' at ' + (outer.style.getPropertyValue('--xdict-space-at') || '-') + ') <' + lb + '>'); }
            var n = img.hasAttribute('data-xdict-captioned') ? null : next(outer);
            if (n) { var down = edge(n, false) - outer.getBoundingClientRect().bottom; note('G17', down >= PX.image - 2, where + 'space below ' + Math.round(down) + ', want at least ' + Math.round(PX.image) + ' before ' + (n.nodeType === 3 ? 'text' : label(n)) + ' <' + lb + '>'); }
          } else if (kind === 'float') {
            var col = body.getBoundingClientRect().width - parseFloat(getComputedStyle(body).paddingLeft) - parseFloat(getComputedStyle(body).paddingRight);
            note('G17', r.width <= Math.min(0.4 * col, 12 * em) + 1 && r.height <= 16 * em + 1, where + 'over 40% × 16em: ' + Math.round(r.width) + '×' + Math.round(r.height) + ' <' + lb + '>');
            var endSide = st.float === 'inline-end' || (st.float === 'right') === (st.direction !== 'rtl') && st.float !== 'inline-start';
            var facing = getComputedStyle(img).getPropertyValue(endSide === (st.direction !== 'rtl') ? 'margin-left' : 'margin-right');
            note('G17', Math.abs(parseFloat(facing) - PX['space-4']) <= 2, where + 'space facing text ' + facing + ' <' + lb + '>');
            var holder = img.parentElement; while (holder && inl(getComputedStyle(holder))) holder = holder.parentElement;
            if (holder) note('G17', r.bottom <= holder.getBoundingClientRect().bottom + 1, where + 'not cleared by its block <' + lb + '>');
          } else if (kind !== 'table' && kind !== 'text') {
            var pe = parseFloat(getComputedStyle(img.parentElement).fontSize);
            note('G17', r.height <= 1.25 * pe + 0.5, where + Math.round(r.height) + 'px tall at ' + pe + 'px <' + lb + '>');
            var base = document.createElement('span'); base.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline';
            img.after(base); var bl = base.getBoundingClientRect().bottom; base.remove();
            note('G17', Math.abs(r.bottom - bl) <= 0.25 * pe + 0.5, where + 'off the baseline by ' + Math.round(r.bottom - bl) + 'px <' + lb + '>');
          }
          if (dark && /^(illustration|inline|float|table)$/.test(kind) && transparent(img)) {
            note('G17', st.backgroundColor === PLATE, where + 'transparent without the plate <' + lb + '>');
          }
        });
        var height = Math.round(document.documentElement.scrollHeight);
        Object.keys(G).forEach(function (k) { var c = G[k];
          c.values = Object.keys(c.values).sort(function (a, b) { return c.values[b] - c.values[a]; }).slice(0, 12).map(function (v) { return [v, c.values[v]]; }); });
        G.height = height;
        return G;
        """#

    /// G16 and G17 over the widths, merged; the window is left at the gallery's width.
    static func spaceChecks(_ webView: WKWebView?, window: NSWindow, control: Bool) async -> [String: Any] {
        var merged: [String: [String: Any]] = ["G16": ["total": 0, "off": 0, "inline": 0, "first": 0], "G17": ["total": 0, "off": 0]]
        var values: [String: [String: Int]] = ["G16": [:], "G17": [:]]
        // The entry's height at each width, for the densities' comparison.
        var heights: [String: Int] = [:]
        for width in spaceWidths {
            window.setContentSize(NSSize(width: width, height: size.height))
            try? await Task.sleep(for: .milliseconds(400))
            // A script that throws measured nothing: both checks fail, never a quiet 0 of 0.
            guard let page = await run(spaceScript(width: width, control: control), webView) else {
                for name in ["G16", "G17"] {
                    merged[name]?["missing"] = true
                    values[name]?["not measured at \(Int(width)) (the script threw)", default: 0] += 1
                }
                continue
            }
            if let h = (page["height"] as? NSNumber)?.intValue { heights[String(Int(width))] = h }
            for name in ["G16", "G17"] {
                guard let c = page[name] as? [String: Any] else { continue }
                for field in ["total", "off", "inline", "first"] {
                    if let n = (c[field] as? NSNumber)?.intValue, let had = merged[name]?[field] as? Int { merged[name]?[field] = had + n }
                }
                for pair in c["values"] as? [[Any]] ?? [] {
                    if let v = pair.first as? String, let n = (pair.last as? NSNumber)?.intValue { values[name]?[v, default: 0] += n }
                }
            }
        }
        window.setContentSize(size)
        try? await Task.sleep(for: .milliseconds(300))
        for name in ["G16", "G17"] {
            let sorted = (values[name] ?? [:]).sorted { $0.value > $1.value }.prefix(12)
            merged[name]?["values"] = sorted.map { [$0.key, $0.value] as [Any] }
            if merged[name]?["missing"] != nil { merged[name]?["off"] = 1 }
        }
        merged["G16"]?["heights"] = heights
        return merged
    }

    /// Lab only: `XDICT_LAB_OPEN_PICTURES=1` opens XDict's fold of the pictures the dictionary hid before the snapshot.
    static var openPictures: String? {
        guard ProcessInfo.processInfo.environment["XDICT_LAB_OPEN_PICTURES"] == "1" else { return nil }
        return "var h = document.querySelector('#xdict-pictures > [data-xdict-control=disclosure]');"
            + "if (h && h.getAttribute('aria-expanded') !== 'true') h.click();"
            + "await new Promise(function (r) { setTimeout(r, 700); }); return {};"
    }
}

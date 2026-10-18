import AppKit
import Foundation
import WebKit
import XDictEntryView
import XDictTokens

/// **The gallery's check of the phonetic face** (owner, 2026-10-16; made from the IPA study's used-font check,
/// `dev-docs/artifacts/reading-frame/ipa-font/`): on a framed page, every shown transcription's text (up to twelve,
/// outside its tags, labels, icons and controls) is drawn in XDict's bundled face for the reading style — "XDict
/// Phonetic Sans" (Noto Sans) or "XDict Phonetic Serif" (Charis) — and that face was loaded from the bundle. Which face
/// drew a text is read from its width where it is drawn against measure spans in exactly the expected family and in the
/// body's; a text the two faces set to the same width proves nothing and is counted, not passed. The first checked
/// transcription is cropped for the eye.
@MainActor
enum GalleryPhon {
    static func check(_ webView: WKWebView?, crop: URL) async -> [String: Any]? {
        guard let webView, let result = await GalleryRun.run(script, webView) else { return nil }
        var out = result
        if let box = result["box"] as? [String: Double], let x = box["x"], let y = box["y"], let w = box["w"],
           let h = box["h"], w > 0, h > 0 {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: x, y: y, width: w, height: h)
                .insetBy(dx: -Tokens.InstrumentLength.captureMargin, dy: -Tokens.InstrumentLength.captureMargin)
            configuration.snapshotWidth = NSNumber(value: configuration.rect.width * 2)
            if let image = try? await webView.takeSnapshot(configuration: configuration),
               let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
               (try? png.write(to: crop)) != nil {
                out["crop"] = "images/\(crop.lastPathComponent)"
            }
            // Back to the top, where the gallery's other checks found the page.
            _ = await GalleryRun.run("window.scrollTo(0, 0); return {};", webView)
        }
        return out
    }

    /// The failures a result means: a transcription drawn in another face, or the face never loaded.
    static func failures(_ result: [String: Any]) -> [String] {
        let checked = result["checked"] as? Int ?? 0
        guard checked > 0 else { return [] }
        let family = result["family"] as? String ?? "?"
        var out: [String] = []
        if (result["loaded"] as? Int ?? 0) == 0 { out.append("no face of \(family) was loaded") }
        if let wrong = result["wrong"] as? [Any], !wrong.isEmpty {
            out.append("a transcription not drawn in \(family) \(wrong)")
        }
        return out
    }

    static let script = """
        var face = document.documentElement.getAttribute('data-xdict-face') === 'serif' ? 'serif' : 'sans';
        var family = face === 'serif' ? \(jsonString(EntryFonts.serif)) : \(jsonString(EntryFonts.sans));
        if (document.fonts && document.fonts.ready) await document.fonts.ready;
        await new Promise(function (r) { requestAnimationFrame(function () { requestAnimationFrame(r); }); });
        var loaded = 0;
        document.fonts.forEach(function (f) { if (f.family.replace(/"/g, '') === family && f.status === 'loaded') loaded += 1; });
        var skip = '[data-xdict-tag],[data-xdict-icon],[data-xdict-role=label],[data-xdict-control]';
        var bodyFamily = getComputedStyle(document.body).fontFamily;
        function measure(n, text, fam) {
          var cs = getComputedStyle(n.parentElement), span = document.createElement('span');
          span.textContent = text;
          span.style.cssText = 'position:absolute;left:-9999px;top:0;white-space:pre;visibility:hidden';
          span.style.setProperty('font-family', fam, 'important');
          ['fontSize', 'fontWeight', 'fontStyle', 'letterSpacing', 'wordSpacing', 'fontFeatureSettings', 'fontVariant',
           'fontStretch', 'textTransform'].forEach(function (k) { span.style[k] = cs[k]; });
          n.parentElement.appendChild(span);
          var w = span.getBoundingClientRect().width; span.remove(); return w;
        }
        var shown = Array.prototype.filter.call(document.querySelectorAll('[data-xdict-phon]'), function (e) {
          return e.getClientRects().length && !e.parentElement.closest('[data-xdict-phon]');
        }).slice(0, 12);
        var checked = 0, inconclusive = 0, wrong = [], box = null, first = null;
        shown.forEach(function (el) {
          var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), node, drawn = 0, inExpected = 0, inBody = 0, worst = 0, text = '', pieces = [];
          while ((node = walker.nextNode())) {
            var t = node.textContent, a = t.search(/\\S/), b = t.length - t.split('').reverse().join('').search(/\\S/);
            if (a < 0 || node.parentElement.closest(skip) || !node.parentElement.getClientRects().length) continue;
            if (/^\\p{M}/u.test(t.slice(a))) continue;
            // A separator alone (CEPD's ";", NOAD's ",") is no evidence of the face, and its drawn box was measured
            // 1.5 px off its measure span while the transcription beside it matched to the tenth (gallery 2026-10-16).
            if (/^[\\s\\p{P}]+$/u.test(t)) continue;
            var piece = t.slice(a, b), range = document.createRange(); range.setStart(node, a); range.setEnd(node, b);
            var d = 0, rects = range.getClientRects(); Array.prototype.forEach.call(rects, function (r) { d += r.width; });
            var x = measure(node, piece, '"' + family + '"');
            var slack = Math.max(0, rects.length - 1) * measure(node, ' ', '"' + family + '"');
            drawn += d; inExpected += x; inBody += measure(node, piece, bodyFamily);
            worst = Math.max(worst, Math.abs(d - x) - 0.5 - 0.01 * x - slack);
            text += piece + ' '; pieces.push([piece.slice(0, 12), Math.round(d * 10) / 10, Math.round(x * 10) / 10, rects.length, node.parentElement.tagName + (node.parentElement.getAttribute('data-xdict-hug') !== null ? '+hug' : '')]);
          }
          if (!text) return;
          if (Math.abs(inExpected - inBody) < 0.5) { inconclusive += 1; return; }
          checked += 1;
          if (!first) first = el;
          // The study's rule: drawn as the expected face measures, or nearer it than the body's.
          if (worst > 0 && Math.abs(drawn - inExpected) >= Math.abs(drawn - inBody)) {
            wrong.push([text.trim().slice(0, 40), getComputedStyle(el).fontFamily.slice(0, 40), Math.round(drawn * 10) / 10,
                        Math.round(inExpected * 10) / 10, Math.round(inBody * 10) / 10, JSON.stringify(pieces).slice(0, 400)]);
          }
        });
        if (first) {
          first.scrollIntoView({ block: 'center', inline: 'nearest' });
          await new Promise(function (r) { requestAnimationFrame(function () { requestAnimationFrame(r); }); });
          var r = first.getBoundingClientRect();
          box = { x: r.left, y: r.top, w: r.width, h: r.height };
        }
        return { family: family, loaded: loaded, shown: shown.length, checked: checked, inconclusive: inconclusive,
                 wrong: wrong.slice(0, 6), box: box };
        """

    static func jsonString(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) }
            ?? "''"
    }
}

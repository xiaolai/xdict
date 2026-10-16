import AppKit
import Foundation
import WebKit
import XDictEntryView

/// **The reading frame's gallery** (owner, 2026-10-15): three entries of every dictionary — the shortest, the longest
/// and the one with the most images or tables among a spread of the sample — rendered light and dark, before (no frame)
/// and after (`EntryReadingFrame.all`), each snapshotted with `takeSnapshot` (no Screen Recording or Accessibility
/// needed) and measured by the frame's own `measure()`. `Tools/gallery/page.py` turns the report into the page.
@MainActor
enum GalleryRun {
    static let candidates = 12
    static let size = NSSize(width: 820, height: 900)
    /// The shell's world: the frame's `measure()` lives there.
    static let shellWorld = WKContentWorld.world(name: "xdict-entry")

    struct Mode {
        let name: String
        let frame: EntryReadingFrame
        let theme: EntryTheme
        /// The reader's "Original style" (ADR-0010 Q3): the core's rendering without normalization, and no frame.
        var original = false
    }

    /// The views the merged tree can render. "before" and "after" (frame only) need a core without normalization, so
    /// a run of the merged tree renders the frame + core views and reuses an earlier report's entries (`--keys`).
    static let modes = [Mode(name: "core-light", frame: .all, theme: .original),
                        Mode(name: "core-dark", frame: .all, theme: .dark),
                        Mode(name: "coreserif-light", frame: [.column, .type, .serif], theme: .original),
                        Mode(name: "coreserif-dark", frame: [.column, .type, .serif], theme: .dark)]

    /// `--original-style`: the same entries in XDict's reading style and in the dictionary's own, side by side.
    static let originalModes = [Mode(name: "core-light", frame: .all, theme: .original),
                                Mode(name: "original-light", frame: .minimal, theme: .original, original: true),
                                Mode(name: "core-dark", frame: .all, theme: .dark),
                                Mode(name: "original-dark", frame: .minimal, theme: .dark, original: true)]

    static func run(options: LabOptions, core: LabCore) async throws -> [String: Any] {
        guard let root = options.fixture, let samplePath = options.sample, let out = options.out else {
            throw LabFailure(description: "--gallery needs a folder, --sample and --out")
        }
        let images = out.deletingLastPathComponent().appending(path: "images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let sample = try JSONDecoder().decode([SampledEntry].self, from: Data(contentsOf: samplePath))
        let byDict = Dictionary(grouping: sample, by: \.dict)
        let previous = try keys(options.keys, sample: sample)
        var rows: [[String: Any]] = []
        var failures: [String] = []
        for name in byDict.keys.sorted() where options.only.isEmpty || options.only.contains(name) {
            let content = try core.open(root.appending(path: name))
            let chosen: [(String, SampledEntry)]
            if let earlier = previous[name] {
                chosen = earlier.map { ($0.kind, SampledEntry(dict: name, key: $0.key, occurrence: $0.occurrence)) }
            } else {
                chosen = await choose(byDict[name] ?? [], content: content, failures: &failures)
            }
            let original = options.originalStyle ? try core.open(root.appending(path: name), originalStyle: true) : nil
            for mode in options.originalStyle ? originalModes : modes {
                let content = mode.original ? original ?? content : content
                let log = EventLog()
                var environment = CorpusRun.environment("gallery-\(mode.name)", log: log)
                environment.readingFrame = mode.frame
                let controller = EntryViewController(environment: environment)
                let window = labWindow("\(name) \(mode.name)", frame: NSRect(origin: NSPoint(x: 80, y: 60), size: size),
                                       view: controller.view)
                var themed = false
                for (kind, entry) in chosen {
                    let reference = EntryReference(key: entry.key, occurrence: entry.occurrence)
                    var before = log.finishedCount
                    guard await controller.show(reference, from: content), await log.waitForFinished(before + 1, seconds: 20) else {
                        failures.append("\(name) \(mode.name) \(entry.key): did not finish loading")
                        continue
                    }
                    if !themed {
                        themed = true
                        if controller.theme != mode.theme {
                            before = log.finishedCount
                            controller.setTheme(mode.theme)
                            _ = await log.waitForFinished(before + 1, seconds: 20)
                        }
                    }
                    try await Task.sleep(for: .milliseconds(500))
                    let file = "\(name)-\(kind)-\(mode.name).jpg"
                    let measured = await measure(controller.webView)
                    // Every text colour on a framed page is a palette token's value in that theme.
                    if !mode.frame.subtracting(.minimal).isEmpty, let stray = measured?["nonToken"] as? [[Any]], !stray.isEmpty {
                        failures.append("\(name) \(mode.name) \(entry.key): text colours outside the palette \(stray)")
                    }
                    if let webView = controller.webView, let image = try? await webView.takeSnapshot(configuration: nil),
                       let data = jpeg(image) {
                        try data.write(to: images.appending(path: file))
                    } else {
                        failures.append("\(name) \(mode.name) \(entry.key): no snapshot")
                    }
                    let phon = mode.frame.isEmpty ? nil
                        : await GalleryPhon.check(controller.webView, crop: images.appending(path: "\(name)-\(kind)-\(mode.name)-phon.png"))
                    if let phon {
                        failures += GalleryPhon.failures(phon).map { "\(name) \(mode.name) \(entry.key): \($0)" }
                    }
                    // After the snapshot: the fold check clicks the page.
                    let layout = mode.frame.subtracting(.minimal).isEmpty ? nil : await run(layoutScript, controller.webView)
                    if let layout {
                        for (key, limit, what) in [("dotWorst", 0.05, "a marker dot is not round"),
                                                   ("pronOff", 0.0, "a speaker off its transcription's line"),
                                                   ("labelGapOver", 0.0, "a label too far from the next text"),
                                                   ("foldGapOver", 0.0, "fold heads too far apart"),
                                                   ("spacePunct", 0.0, "a space before punctuation after a label")] {
                            if let v = layout[key] as? Double, v > limit {
                                failures.append("\(name) \(mode.name) \(entry.key): \(what) (\(key) \(v))")
                            }
                        }
                    }
                    let marked = mode.frame.subtracting(.minimal).isEmpty ? nil : await marks(controller.webView)
                    if let marked {
                        if let leaks = marked["leaks"] as? [Any], !leaks.isEmpty {
                            failures.append("\(name) \(mode.name) \(entry.key): a dictionary glyph drawn where the core marked one \(leaks)")
                        }
                        if let low = marked["labelLowest"] as? Double, low < 4.5 {
                            failures.append("\(name) \(mode.name) \(entry.key): a label at \(low):1")
                        }
                        if let wrong = marked["foldMismatch"] as? [Any], !wrong.isEmpty {
                            failures.append("\(name) \(mode.name) \(entry.key): the chevron does not match its fold \(wrong)")
                        }
                    }
                    rows.append(["dict": name, "kind": kind, "key": entry.key, "mode": mode.name, "image": "images/\(file)",
                                 "measure": measured ?? NSNull(), "marks": marked ?? NSNull(),
                                 "layout": layout ?? NSNull(), "phon": phon ?? NSNull()])
                }
                controller.closeEntry()
                window.close()
            }
        }
        return ["mode": "gallery", "rows": rows, "failures": failures,
                "folding": try await CorpusRun.folding(root: root, core: core)]
    }

    /// The entries an earlier report showed, per dictionary, so that every view shows the same ones.
    static func keys(_ report: URL?, sample: [SampledEntry]) throws -> [String: [(kind: String, key: String, occurrence: UInt32)]] {
        guard let report else { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        var out: [String: [(kind: String, key: String, occurrence: UInt32)]] = [:]
        for row in object?["rows"] as? [[String: Any]] ?? [] {
            guard let dict = row["dict"] as? String, let kind = row["kind"] as? String, let key = row["key"] as? String,
                  out[dict, default: []].contains(where: { $0.kind == kind }) == false else { continue }
            let occurrence = sample.first { $0.dict == dict && $0.key == key }?.occurrence ?? 0
            out[dict, default: []].append((kind, key, occurrence))
        }
        return out
    }

    /// The shortest, the longest, and the richest in images and tables, among an even spread of the sample.
    static func choose(_ entries: [SampledEntry], content: CoreContent, failures: inout [String]) async
        -> [(String, SampledEntry)] {
        guard !entries.isEmpty else { return [] }
        let step = max(1, entries.count / candidates)
        let spread = stride(from: 0, to: entries.count, by: step).prefix(candidates).map { entries[$0] }
        let log = EventLog()
        var environment = CorpusRun.environment("gallery-choose", log: log)
        environment.readingFrame = []
        let controller = EntryViewController(environment: environment)
        let window = labWindow("choose", frame: NSRect(origin: NSPoint(x: 80, y: 60), size: size), view: controller.view)
        defer { controller.closeEntry(); window.close() }
        var surveyed: [(entry: SampledEntry, chars: Int, media: Int)] = []
        for entry in spread {
            let before = log.finishedCount
            guard await controller.show(EntryReference(key: entry.key, occurrence: entry.occurrence), from: content),
                  await log.waitForFinished(before + 1, seconds: 20),
                  let found = await labEvaluate(controller.webView, """
                      return [document.body ? document.body.innerText.length : 0,
                              document.images.length + document.querySelectorAll('table').length];
                      """) as? [Int], found.count == 2 else { continue }
            surveyed.append((entry, found[0], found[1]))
        }
        let readable = surveyed.filter { $0.chars >= 40 }
        guard let short = readable.min(by: { $0.chars < $1.chars }), let long = readable.max(by: { $0.chars < $1.chars }) else {
            failures.append("\(entries[0].dict): no entry with text among \(spread.count)")
            return []
        }
        var chosen = [("short", short.entry), ("long", long.entry)]
        let rest = readable.filter { $0.entry.key != short.entry.key && $0.entry.key != long.entry.key }
        if let rich = rest.max(by: { ($0.media, $0.chars) < ($1.media, $1.chars) }) { chosen.append(("media", rich.entry)) }
        return chosen
    }

    static func measure(_ webView: WKWebView?) async -> [String: Any]? {
        guard let webView else { return nil }
        let value = try? await webView.callAsyncJavaScript("return window.__xdictFrame ? window.__xdictFrame.measure() : null",
                                                           arguments: [:], in: nil, contentWorld: shellWorld)
        return value as? [String: Any]
    }

    /// The marks, measured (icon sweep §8): every pseudo-element the core marked draws XDict's box or nothing, never
    /// the dictionary's content or sprite; every label's computed contrast against what is behind it; and each fold
    /// head (up to eight) clicked, its `aria-expanded` compared with its fold's shown state once the page has answered.
    static let marksScript = """
        var leaks = [], marked = 0;
        document.querySelectorAll('[data-xdict-before],[data-xdict-after]').forEach(function (el) {
          ['before', 'after'].forEach(function (side) {
            var mark = el.getAttribute('data-xdict-' + side);
            if (!mark) return;
            marked += 1;
            var ps = getComputedStyle(el, '::' + side), content = ps.content;
            var ok = (mark === 'marker' || mark === 'lookup') ? (content === '""' || content === "''") : (content === 'none' || content === 'normal');
            if (!ok || ps.backgroundImage !== 'none') {
              if (leaks.length < 6) leaks.push([el.tagName.toLowerCase() + '.' + String(el.className).split(' ')[0], side, mark, content, ps.backgroundImage.slice(0, 40)]);
              else leaks.push(1);
            }
          });
        });
        var labels = document.querySelectorAll('[data-xdict-role=label]'), lowest = null, labelCount = 0;
        labels.forEach(function (el) {
          if (!el.getClientRects().length) return;
          labelCount += 1;
          var fg = XDictReadability.parse(getComputedStyle(el).color), bg = null;
          for (var e = el; e && !bg; e = e.parentElement) {
            var c = XDictReadability.parse(getComputedStyle(e).backgroundColor);
            if (c && c[3] >= 0.5) bg = c;
          }
          if (!bg) bg = XDictReadability.parse(getComputedStyle(document.documentElement).backgroundColor) || [255, 255, 255, 1];
          if (fg) { var r = XDictReadability.contrast(fg, bg); if (lowest === null || r < lowest) lowest = r; }
        });
        var heads = Array.prototype.filter.call(document.querySelectorAll('[data-xdict-control=disclosure]'),
          function (h) { return h.getClientRects().length > 0; });
        var mismatch = [], clicked = 0, stated = 0;
        function state(h) {
          var t = XDictDisclosureCore.target(h, function (id) { return document.getElementById(id); });
          return t ? (t.checkVisibility({ visibilityProperty: true }) ? 'true' : 'false') : null;
        }
        heads.forEach(function (h) { if (h.getAttribute('aria-expanded') !== null) stated += 1; });
        for (var i = 0; i < heads.length && i < 8; i++) {
          var h = heads[i], href = h.getAttribute('href');
          if (href !== null && href.charAt(0) !== '#') continue;
          if (h.getAttribute('aria-expanded') !== state(h)) mismatch.push([i, 'before', h.getAttribute('aria-expanded'), state(h)]);
          h.click();
          clicked += 1;
          await new Promise(function (r) { setTimeout(r, 450); });
          if (h.getAttribute('aria-expanded') !== state(h)) mismatch.push([i, 'after', h.getAttribute('aria-expanded'), state(h), (h.textContent || '').trim().slice(0, 24)]);
        }
        return { marked: marked, leaks: leaks, labels: labelCount,
                 labelLowest: lowest === null ? null : Math.round(lowest * 100) / 100,
                 heads: heads.length, stated: stated, clicked: clicked, foldMismatch: mismatch };
        """

    /// The marks' layout, measured (coordinator's review of oald-long, 2026-10-16), with samples for diagnosis:
    /// - `dotWorst`: the largest |width / height − 1| of a marker dot;
    /// - `pronOff`: speakers whose next transcription is on another line box (the speaker's middle outside its rect);
    /// - `labelGapOver`: labels that replace a drawing whose next visible text on the same line starts more than the gap token after them;
    /// - `foldGapOver`: consecutive fold heads (nothing visible between) whose texts are further apart than the line's
    ///   leading plus the gap token (the list rhythm);
    /// - `spacePunct`: labels followed by whitespace and then `,` `;` or `.`.
    static let layoutScript = #"""
        function probeBox(el) { if (!el) return null; var cs = getComputedStyle(el), r = el.getBoundingClientRect();
          return [el.tagName.toLowerCase() + '.' + String(el.className), cs.display, cs.width, cs.margin, cs.padding, Math.round(r.left), Math.round(r.right)]; }
        var gap = parseFloat(getComputedStyle(document.documentElement).fontSize) * 0.5 + 1;
        function trim(el) { return el ? el.outerHTML.replace(/\s+/g, ' ').slice(0, 300) : ''; }
        function seen(el) { return el.getClientRects().length > 0; }
        var dotWorst = 0, dots = [];
        document.querySelectorAll('[data-xdict-before=marker],[data-xdict-after=marker]').forEach(function (el) {
          ['before', 'after'].forEach(function (side) {
            if (el.getAttribute('data-xdict-' + side) !== 'marker' || !seen(el)) return;
            var ps = getComputedStyle(el, '::' + side), w = parseFloat(ps.width) + parseFloat(ps.paddingLeft) + parseFloat(ps.paddingRight),
                h = parseFloat(ps.height) + parseFloat(ps.paddingTop) + parseFloat(ps.paddingBottom);
            if (!(h > 0)) return;
            var d = Math.abs(w / h - 1);
            if (d > dotWorst) { dotWorst = d; dots = [ps.width, ps.height, ps.padding, ps.display, trim(el).slice(0, 120)]; }
          });
        });
        // The next element after `el` in document order matching `sel`, within `el`'s grandparent.
        function nextIn(el, sel, scope) {
          var all = scope.querySelectorAll(sel);
          for (var i = 0; i < all.length; i++) {
            if (el.compareDocumentPosition(all[i]) & Node.DOCUMENT_POSITION_FOLLOWING) return all[i];
          }
          return null;
        }
        var pronOff = 0, pronTotal = 0, pron = [];
        document.querySelectorAll('[data-xdict-control=speaker]').forEach(function (sp) {
          if (!seen(sp)) return;
          var scope = sp.parentElement && sp.parentElement.parentElement ? sp.parentElement.parentElement : document.body;
          // Its transcription: the text after it inside a transcription that holds it, else the next one near it.
          var ph = null, b = null;
          if (sp.closest('[data-xdict-phon]')) { var tn = nextText(sp); if (tn && tn.parentElement.closest('[data-xdict-phon]')) ph = tn; }
          else { var pe = nextIn(sp, '[data-xdict-phon]', scope); if (pe && seen(pe)) ph = pe; }
          if (!ph) return;
          if (ph.nodeType === 3) { var tr = document.createRange(); tr.selectNodeContents(ph); b = tr.getClientRects()[0]; } else b = ph.getClientRects()[0];
          if (!b) return;
          pronTotal += 1;
          var a = sp.getBoundingClientRect(), mid = (a.top + a.bottom) / 2;
          if (mid < b.top || mid > b.bottom) {
            pronOff += 1;
            if (pron.length < 3) {
              var chain = [];
              for (var e = sp; e && e !== document.body && chain.length < 4; e = e.parentElement) {
                var cs = getComputedStyle(e); chain.push(e.tagName.toLowerCase() + '.' + String(e.className).split(' ')[0] + ' ' + cs.display + '/' + cs.float + '/' + cs.position);
              }
              pron.push([chain, trim(sp.parentElement && sp.parentElement.parentElement)]);
            }
          }
        });
        function nextText(el) {
          var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), n = null;
          w.currentNode = el;
          while ((n = w.nextNode())) {
            if (el.contains(n)) continue;
            if (!/\S/.test(n.nodeValue) || !n.parentElement || !seen(n.parentElement)) continue;
            return n;
          }
          return null;
        }
        function between(el, n) {
          var r = document.createRange(); r.setStartAfter(el); r.setEnd(n, 0); return r.toString();
        }
        var labelGapOver = 0, labelGaps = [], spacePunct = 0, punct = [];
        // The labels that replace a drawing (icon sweep §8.2); a dictionary's own text labels keep its layout.
        document.querySelectorAll('[data-xdict-role=label]:is([data-xdict-label=level],[data-xdict-label=wordlist],[data-xdict-label=frequency],[data-xdict-label=new])').forEach(function (lb) {
          if (!seen(lb)) return;
          var n = nextText(lb);
          if (!n) return;
          var r = document.createRange(); r.selectNodeContents(n);
          var lt = document.createRange(); lt.selectNodeContents(lb);
          var nr = r.getClientRects()[0], lr = lt.getClientRects(); lr = lr[lr.length - 1];
          if (!lr) return;
          if (!nr) return;
          // A control or image between them (a speaker) is content, not a gap.
          var mid = document.createRange(); mid.setStartAfter(lb); mid.setEnd(n, 0);
          var held = Array.prototype.some.call(mid.cloneContents().querySelectorAll('[data-xdict-control],img,svg'), function () { return true; });
          if (!held && Math.abs(nr.top - lr.top) < lr.height && nr.left - lr.right > gap) {
            labelGapOver += 1;
            if (labelGaps.length < 3) labelGaps.push([Math.round(nr.left - lr.right), trim(lb.parentElement), trim(lb.nextElementSibling), probeBox(lb), probeBox(lb.parentElement), probeBox(n.parentElement), n.nodeValue.slice(0, 20)]);
          }
        });
        // Punctuation the source set against the text before it, drawn more than 0.2em away from it.
        (function () {
          var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), prev = null, k = 0, n;
          while ((n = w.nextNode()) && k < 6000) {
            if (!/\S/.test(n.nodeValue) || !n.parentElement || !seen(n.parentElement)) { if (/\s/.test(n.nodeValue)) prev = null; continue; }
            k += 1;
            // A space the dictionary's own sheet draws after the element (`::after{content:" "}`) is the source's.
            var drawnSpace = prev && /^"\s+"$/.test(getComputedStyle(prev.parentElement, '::after').content);
            if (prev && !drawnSpace && /^[,;.]/.test(n.nodeValue) && !/\s$/.test(prev.nodeValue)) {
              var a = document.createRange(); a.selectNodeContents(prev); var ar = a.getClientRects(); ar = ar[ar.length - 1];
              var c = document.createRange(); c.setStart(n, 0); c.setEnd(n, 1); var cr = c.getClientRects()[0];
              var em = parseFloat(getComputedStyle(n.parentElement).fontSize);
              if (ar && cr && Math.abs(cr.top - ar.top) < ar.height && cr.left - ar.right > 0.2 * em) {
                spacePunct += 1;
                if (punct.length < 3) { var pe = prev.parentElement, pa2 = getComputedStyle(pe, '::after');
                  punct.push([Math.round(cr.left - ar.right), prev.nodeValue.slice(-12) + '|' + n.nodeValue.slice(0, 6), trim(n.parentElement.parentElement).slice(0, 200),
                              probeBox(pe), pa2.content, pa2.width, pa2.margin, getComputedStyle(pe).fontStyle, getComputedStyle(pe).letterSpacing]); }
              }
            }
            prev = /\s$/.test(n.nodeValue) ? null : n;
          }
        })();
        var heads = Array.prototype.filter.call(document.querySelectorAll('[data-xdict-control=disclosure]'), seen);
        var foldGapOver = 0, folds = [];
        for (var i = 1; i < heads.length; i++) {
          var p = heads[i - 1], q = heads[i];
          // Consecutive: no visible text between the two heads but their folds' hidden text.
          var t = nextText(p), visibleBetween = false;
          if (t && (q.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_PRECEDING) && !q.contains(t)) visibleBetween = true;
          if (visibleBetween) continue;
          var pr = document.createRange(); pr.selectNodeContents(p); var pa = pr.getClientRects(); pa = pa[pa.length - 1];
          var qr = document.createRange(); qr.selectNodeContents(q); var qa = qr.getClientRects()[0];
          if (!pa || !qa) continue;
          var d = qa.top - pa.bottom, qs = getComputedStyle(q), fs = parseFloat(qs.fontSize);
          var lead = qs.lineHeight === 'normal' ? 0.2 * fs : parseFloat(qs.lineHeight) - fs;
          // The list rhythm: the line's own leading plus the gap token between blocks.
          if (d > lead + gap) { foldGapOver += 1; if (folds.length < 3) folds.push([Math.round(d), trim(p).slice(0, 150)]); }
        }
        return { dotWorst: Math.round(dotWorst * 1000) / 1000, dots: dots, pronOff: pronOff, pronTotal: pronTotal, pron: pron,
                 labelGapOver: labelGapOver, labelGaps: labelGaps, foldGapOver: foldGapOver, folds: folds,
                 foldHeads: heads.length, spacePunct: spacePunct, punct: punct };
        """#

    static func run(_ script: String, _ webView: WKWebView?) async -> [String: Any]? {
        guard let webView else { return nil }
        return (try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: shellWorld))
            as? [String: Any]
    }

    static func marks(_ webView: WKWebView?) async -> [String: Any]? {
        guard let webView else { return nil }
        return (try? await webView.callAsyncJavaScript(marksScript, arguments: [:], in: nil, contentWorld: shellWorld))
            as? [String: Any]
    }

    static func jpeg(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

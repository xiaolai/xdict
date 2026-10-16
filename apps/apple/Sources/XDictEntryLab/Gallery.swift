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
        let style = try options.style()
        var rows: [[String: Any]] = []
        var failures: [String] = []
        // Rows the run means to write: the runner holds the report to it, so a run that ends early is not read as done.
        var expected = 0
        for name in byDict.keys.sorted() where options.only.isEmpty || options.only.contains(name) {
            let content = try core.open(root.appending(path: name))
            let chosen: [(String, SampledEntry)]
            if options.spread > 0, let all = byDict[name], !all.isEmpty {
                let step = max(1, all.count / options.spread)
                chosen = stride(from: 0, to: all.count, by: step).prefix(options.spread).enumerated()
                    .map { ("spread\($0.offset + 1)", all[$0.element]) }
            } else if let earlier = previous[name] {
                chosen = earlier.map { ($0.kind, SampledEntry(dict: name, key: $0.key, occurrence: $0.occurrence)) }
            } else {
                chosen = await choose(byDict[name] ?? [], content: content, failures: &failures)
            }
            let original = options.originalStyle ? try core.open(root.appending(path: name), originalStyle: true) : nil
            expected += chosen.count * (options.originalStyle ? originalModes : modes).count
            for mode in options.originalStyle ? originalModes : modes {
                let content = mode.original ? original ?? content : content
                let log = EventLog()
                var environment = CorpusRun.environment("gallery-\(mode.name)", log: log)
                environment.readingFrame = mode.frame
                environment.style = style
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
                    if !mode.frame.isEmpty, let accent = accentCandidate { _ = await run(accent, controller.webView) }
                    if !mode.frame.isEmpty, let control = positiveControl { _ = await run(control, controller.webView) }
                    try await Task.sleep(for: .milliseconds(500))
                    let file = "\(name)-\(kind)-\(mode.name).jpg"
                    let measured = await measure(controller.webView)
                    // Every text colour on a framed page is a palette token's value in that theme. Text drawn fully
                    // transparent draws nothing (YHDCD's `.Z_Z{color:transparent}` " | " spacer) and has no colour.
                    let stray = (measured?["nonToken"] as? [[Any]] ?? []).filter {
                        ($0.first as? String)?.range(of: #"^rgba\(.*,\s*0\)$"#, options: .regularExpression) == nil
                    }
                    if !mode.frame.isEmpty, !mode.original, !stray.isEmpty {
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
                    let layout = mode.frame.isEmpty ? nil : await run(layoutScript, controller.webView)
                    if let layout {
                        for (key, limit, what) in [("dotWorst", 0.05, "a marker dot is not round"),
                                                   ("dotSquare", 0.0, "a marker dot with square corners"),
                                                   ("pronOff", 0.0, "a speaker off its transcription's line"),
                                                   ("labelGapOver", 0.0, "a label too far from the next text"),
                                                   ("foldGapOver", 0.0, "fold heads too far apart"),
                                                   ("spacePunct", 0.0, "a space before punctuation after a label"),
                                                   ("labelTight", 0.0, "a label or tag against the next text"),
                                                   ("speakerTight", 0.0, "a speaker against the word before it"),
                                                   ("markerOff", 0.0, "a marker off its item's first line"),
                                                   ("chevronOff", 0.0, "a chevron off its head's first line"),
                                                   ("levelPill", 0.0, "a level pill the dictionary still draws"),
                                                   ("foldSign", 0.0, "a dictionary fold sign beside the chevron")] {
                            if let v = layout[key] as? Double, v > limit {
                                failures.append("\(name) \(mode.name) \(entry.key): \(what) (\(key) \(v))")
                            }
                        }
                        // The reading style's Q9; Original style keeps the dictionary's own rules.
                        if !mode.original, let v = layout["hrDrawn"] as? Double, v > 0 {
                            failures.append("\(name) \(mode.name) \(entry.key): a rule drawn as a line (hrDrawn \(v) \(layout["hrs"] ?? ""))")
                        }
                    }
                    // R's invariants are the reading style's; Original style keeps the dictionary's own.
                    let invariants = mode.frame.isEmpty || mode.original ? nil : await run(invariantsScript, controller.webView)
                    if !mode.frame.isEmpty && !mode.original {
                        failures += invariantFailures(invariants, where: "\(name) \(mode.name) \(entry.key)")
                    }
                    let marked = mode.frame.isEmpty ? nil : await marks(controller.webView)
                    if let marked {
                        if let leaks = marked["leaks"] as? [Any], !leaks.isEmpty {
                            failures.append("\(name) \(mode.name) \(entry.key): a dictionary glyph drawn where the core marked one \(leaks)")
                        }
                        if let low = marked[mode.original ? "drawnLowest" : "labelLowest"] as? Double, low < 4.5 {
                            failures.append("\(name) \(mode.name) \(entry.key): a label at \(low):1")
                        }
                        if let wrong = marked["foldMismatch"] as? [Any], !wrong.isEmpty {
                            failures.append("\(name) \(mode.name) \(entry.key): the chevron does not match its fold \(wrong)")
                        }
                    }
                    rows.append(["dict": name, "kind": kind, "key": entry.key, "mode": mode.name, "image": "images/\(file)",
                                 "measure": measured ?? NSNull(), "marks": marked ?? NSNull(),
                                 "layout": layout ?? NSNull(), "phon": phon ?? NSNull(),
                                 "invariants": invariants ?? NSNull()])
                }
                controller.closeEntry()
                window.close()
            }
        }
        return ["mode": "gallery", "style": options.styleDir?.path ?? "bundled", "rows": rows, "expected": expected, "failures": failures,
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
        var lowestAt = "", drawnLowest = null;
        labels.forEach(function (el) {
          if (!el.getClientRects().length) return;
          labelCount += 1;
          var fg = XDictReadability.parse(getComputedStyle(el).color), bg = null;
          for (var e = el; e && !bg; e = e.parentElement) {
            var c = XDictReadability.parse(getComputedStyle(e).backgroundColor);
            if (c && c[3] >= 0.5) bg = c;
          }
          if (!bg) bg = XDictReadability.parse(getComputedStyle(document.documentElement).backgroundColor) || [255, 255, 255, 1];
          // XDict's own labels (those replacing a drawing) are the marks in every style; a label of the dictionary's
          // words is XDict's only in the reading style (`readingLabelsCSS`), so `drawnLowest` is held in original style.
          var drawn = el.matches('[data-xdict-label=level],[data-xdict-label=wordlist],[data-xdict-label=frequency],[data-xdict-label=new]');
          if (fg && drawn) { var rd = XDictReadability.contrast(fg, bg); if (drawnLowest === null || rd < drawnLowest) drawnLowest = rd; }
          if (fg) { var r = XDictReadability.contrast(fg, bg); if (lowest === null || r < lowest) { lowest = r; lowestAt = el.outerHTML + " IN " + el.parentElement.outerHTML.slice(0, 200) + " BG " + JSON.stringify(bg).replace(/\\s+/g, " ").slice(0, 400); } }
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
                 labelLowestAt: lowestAt,
                 drawnLowest: drawnLowest === null ? null : Math.round(drawnLowest * 100) / 100,
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
        var dotWorst = 0, dots = [], dotSquare = 0, squares = [];
        document.querySelectorAll('[data-xdict-before=marker],[data-xdict-after=marker]').forEach(function (el) {
          ['before', 'after'].forEach(function (side) {
            if (el.getAttribute('data-xdict-' + side) !== 'marker' || !seen(el)) return;
            var ps = getComputedStyle(el, '::' + side), w = parseFloat(ps.width) + parseFloat(ps.paddingLeft) + parseFloat(ps.paddingRight),
                h = parseFloat(ps.height) + parseFloat(ps.paddingTop) + parseFloat(ps.paddingBottom);
            if (!(h > 0)) return;
            var d = Math.abs(w / h - 1);
            if (d > dotWorst) { dotWorst = d; dots = [ps.width, ps.height, ps.padding, ps.display, trim(el).slice(0, 120)]; }
            // A square passes the ratio: each corner's radius must reach half the box.
            var round = ['TopLeft', 'TopRight', 'BottomRight', 'BottomLeft'].every(function (k) {
              var v = ps['border' + k + 'Radius'];
              return /%/.test(v) ? parseFloat(v) >= 50 : parseFloat(v) >= Math.min(w, h) / 2 - 0.01;
            });
            if (!round) { dotSquare += 1; if (squares.length < 3) squares.push([ps.borderRadius, w, h, trim(el).slice(0, 120)]); }
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
          // A speaker that wraps its transcription (OALECD's `<a … data-xdict-phon>`, a prefix control) holds it.
          var own = sp.hasAttribute('data-xdict-phon') ? Array.prototype.find.call(sp.querySelectorAll('*'), function (e) {
            return !e.closest('[data-xdict-icon],[data-xdict-tag]') && /\S/.test(e.textContent) && seen(e) && !e.children.length;
          }) : null;
          if (own) ph = own;
          else if (sp.closest('[data-xdict-phon]')) { var tn = nextText(sp); if (tn && tn.parentElement.closest('[data-xdict-phon]')) ph = tn; }
          else {
            var pe = nextIn(sp, '[data-xdict-phon]', scope);
            // The next transcription is the speaker's only when no word separates them (other speakers aside): a
            // headword's speakers wrapped past its transcription do not own a later run-on's (LDOCE-EC).
            if (pe && seen(pe)) {
              var gapR = document.createRange(); gapR.setStartAfter(sp); gapR.setEndBefore(pe);
              var gapF = gapR.cloneContents();
              Array.prototype.forEach.call(gapF.querySelectorAll('[data-xdict-control]'), function (c) { c.remove(); });
              // A line break the dictionary writes between them (CALD's `<br>` before the transcription line) is its
              // layout: the speaker ends one line and the transcription starts the next.
              if (!/[A-Za-zÀ-ɏ]/.test(gapF.textContent) && !gapF.querySelector('br')) ph = pe;
            }
          }
          if (!ph) return;
          if (ph.nodeType === 3) { var tr = document.createRange(); tr.selectNodeContents(ph); b = tr.getClientRects()[0]; } else b = ph.getClientRects()[0];
          if (!b) return;
          pronTotal += 1;
          var a = sp.getBoundingClientRect(), mid = (a.top + a.bottom) / 2;
          // Wrapping is no excuse: a speaker and the transcription it plays stay on one line (the break goes before the
          // speaker), so a wrap between them counts.
          if (mid < b.top || mid > b.bottom) {
            pronOff += 1;
            if (pron.length < 3) {
              var chain = [];
              for (var e = sp; e && e !== document.body && chain.length < 4; e = e.parentElement) {
                var cs = getComputedStyle(e); chain.push(e.tagName.toLowerCase() + '.' + String(e.className).split(' ')[0] + ' ' + cs.display + '/' + cs.float + '/' + cs.position);
              }
              pron.push([chain, (sp.parentElement && sp.parentElement.parentElement ? (sp.closest("[data-xdict-speakers]:not([data-xdict-speakers] [data-xdict-speakers])") || sp).parentElement.outerHTML.replace(/\s+/g, ' ').slice(0, 4000) : '')]);
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
            // Punctuation set after a control (CED's speaker after a transcription) is against the control, not the text.
            var afterControl = false;
            if (prev) { var cg = document.createRange(); cg.setStartAfter(prev); cg.setEnd(n, 0);
              afterControl = !!cg.cloneContents().querySelector('[data-xdict-control],[data-xdict-icon]'); }
            if (prev && !drawnSpace && !afterControl && /^[,;.]/.test(n.nodeValue) && !/\s$/.test(prev.nodeValue)) {
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
        // A speaker keeps the control spacing (0.25em of the text) from the word before it on its line (CED "filiform").
        var speakerTight = 0, spTight = [];
        document.querySelectorAll('[data-xdict-control=speaker]').forEach(function (sp) {
          if (!seen(sp)) return;
          var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), t = null, n;
          w.currentNode = sp;
          while ((n = w.previousNode())) {
            if (sp.contains(n) || !/\S/.test(n.nodeValue) || !n.parentElement || !seen(n.parentElement)) {
              if (!sp.contains(n) && n.parentElement && seen(n.parentElement) && /\s/.test(n.nodeValue)) break;
              continue;
            }
            t = n; break;
          }
          if (!t || /\s$/.test(t.nodeValue) || t.parentElement.closest('[data-xdict-control]')) return;
          var r = document.createRange(); r.selectNodeContents(t); var tr = r.getClientRects(); tr = tr[tr.length - 1];
          if (!tr) return;
          var tg = sp.querySelector('[data-xdict-tag]'), ic = sp.querySelector('[data-xdict-icon]');
          var first = tg && seen(tg) && tg.getBoundingClientRect().width > 0 ? tg : ic;
          if (!first) return;
          var fr = first.getBoundingClientRect();
          if (Math.abs((fr.top + fr.bottom) / 2 - (tr.top + tr.bottom) / 2) > tr.height) return;
          // The control spacing is the speaker's own (0.25em of its font): after a larger headword it is not scaled up.
          var em = parseFloat(getComputedStyle(sp).fontSize);
          var d = getComputedStyle(sp).direction === 'rtl' ? tr.left - fr.right : fr.left - tr.right;
          if (d < 0.25 * em - 0.5 && d > -em) { speakerTight += 1; if (spTight.length < 3) spTight.push([Math.round(d * 10) / 10, t.nodeValue.slice(-12), trim(sp).slice(0, 120)]); }
        });
        // icon sweep §8.4: a label or an accent tag owns 0.35em of its own before the next word or control on its line.
        var labelTight = 0, tight = [];
        document.querySelectorAll('[data-xdict-role=label],[data-xdict-tag]').forEach(function (lb) {
          if (!seen(lb) || (lb.parentElement && lb.parentElement.closest('[data-xdict-role=label]'))) return;
          var n = nextText(lb);
          // The label's own box (its letter-spacing included, its margin not): where its drawing ends.
          var lr = lb.getClientRects(); lr = lr[lr.length - 1];
          if (!lr) return;
          var nr = null, what = '';
          // A control, label or image before that text is the next thing on the line.
          if (lb.hasAttribute('data-xdict-tag')) {
            var ic = lb.parentElement && lb.parentElement.querySelector('[data-xdict-icon]');
            if (ic && seen(ic)) { nr = ic.getBoundingClientRect(); what = 'icon'; }
          }
          var cands = nr ? [] : document.querySelectorAll('[data-xdict-control],[data-xdict-role=label],[data-xdict-icon],img,svg');
          for (var i = 0; i < cands.length; i++) {
            var c = cands[i];
            if (lb.contains(c) || c.contains(lb) || !seen(c)) continue;
            if (!(lb.compareDocumentPosition(c) & Node.DOCUMENT_POSITION_FOLLOWING)) continue;
            if (n && (c.compareDocumentPosition(n) & Node.DOCUMENT_POSITION_PRECEDING) && !c.contains(n)) break;
            // A speaker is drawn from its accent tag (order -1): the gap runs to the tag's text, not the button's box.
            var tg = c.querySelector('[data-xdict-tag]'), cr = c.getBoundingClientRect();
            if (tg && seen(tg)) cr = tg.getBoundingClientRect();
            else {
              // A control's hit area (padding, offset by a negative margin) is not drawn: its content box is.
              var ccs = getComputedStyle(c), pl = parseFloat(ccs.paddingLeft), pr = parseFloat(ccs.paddingRight);
              cr = { left: cr.left + pl, right: cr.right - pr, top: cr.top + parseFloat(ccs.paddingTop), width: cr.width - pl - pr };
            }
            if (cr.width > 0) { nr = cr; what = [probeBox(c), probeBox(lb.parentElement), trim(c).slice(0, 100)]; }
            break;
          }
          if (!nr && n) {
            // Punctuation set against the label stays against it (§7).
            if (/^[,;.:)\]]/.test(n.nodeValue)) return;
            var r = document.createRange(); r.selectNodeContents(n); nr = r.getClientRects()[0]; what = n.nodeValue.slice(0, 16);
          }
          if (!nr || Math.abs(nr.top - lr.top) >= lr.height) return;
          // A tag's gap is the surrounding text's 0.35em (it is set at 0.625em of it).
          var em = parseFloat(getComputedStyle(lb.hasAttribute('data-xdict-tag') && lb.parentElement ? lb.parentElement : lb).fontSize);
          var d = getComputedStyle(lb).direction === 'rtl' ? lr.left - nr.right : nr.left - lr.right;
          // Far behind the label is not its neighbour: a label the dictionary floats to the line's end (CED).
          if (d < 0.35 * em - 0.5 && d > -em) { labelTight += 1; if (tight.length < 3) tight.push([Math.round(d * 10) / 10, lb.textContent.slice(0, 20), what, probeBox(lb), trim(lb).slice(0, 120), getComputedStyle(lb).marginInlineEnd]); }
        });
        // A mark drawn at the head of a block sits on the line box of the block's first text, whatever display its
        // content has: the marker dot (§3) and the fold chevron (§4).
        function firstTextRect(el) {
          var w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), t;
          while ((t = w.nextNode())) {
            if (!/\S/.test(t.nodeValue) || !t.parentElement || !seen(t.parentElement)) continue;
            var r = document.createRange(); r.selectNodeContents(t); var b = r.getClientRects()[0]; if (b) return b;
          }
          return null;
        }
        function headOff(sel, side, gapEm) {
          var off = 0, out = [], total = 0;
          document.querySelectorAll(sel).forEach(function (el) {
            if (!seen(el)) return;
            var ps = getComputedStyle(el, '::' + side);
            if (ps.content === 'none' || ps.display === 'none') return;
            var t = firstTextRect(el);
            if (!t) return;
            total += 1;
            var cs = getComputedStyle(el), r = el.getBoundingClientRect();
            var top = r.top + parseFloat(cs.borderTopWidth) + parseFloat(cs.paddingTop), h = parseFloat(ps.height);
            var bad = false, mid = null;
            if (ps.position === 'absolute') {
              mid = r.top + parseFloat(cs.borderTopWidth) + parseFloat(ps.top) + h / 2;
              bad = mid < t.top || mid > t.bottom;
              // And it keeps 0.35em of its own before the text (§3), whatever indent the item's content has.
              var w = parseFloat(ps.width), em = parseFloat(ps.fontSize), rtl = cs.direction === 'rtl';
              var markEnd = rtl ? r.right - parseFloat(cs.borderRightWidth) - parseFloat(ps.right) - w
                                : r.left + parseFloat(cs.borderLeftWidth) + parseFloat(ps.left) + w;
              var room = rtl ? markEnd - t.right : t.left - markEnd;
              if (room < gapEm * em - 0.5) { bad = true; mid = 'room ' + Math.round(room * 10) / 10; }
            } else {
              // In flow, the mark opens the block's first line: its first text must be on that line too.
              bad = cs.display !== 'inline' && t.top - top > Math.max(h, t.height / 2);
            }
            if (bad) { off += 1; if (out.length < 3) out.push([ps.position, Math.round(t.top - top), mid === null || typeof mid === 'string' ? mid : Math.round(mid - t.top), trim(el).slice(0, 150), cs.textIndent, cs.paddingLeft, el.firstElementChild ? getComputedStyle(el.firstElementChild).marginLeft + '|' + getComputedStyle(el.firstElementChild).textIndent : '']); }
          });
          return [off, out, total];
        }
        var mk = headOff('[data-xdict-before=marker]', 'before', 0.35), ch = headOff('[data-xdict-control=disclosure]', 'before', 0.25);
        // A CEFR level the dictionary draws as a pill or box is XDict's label, not the dictionary's drawing.
        // Q9: in the reading style a rule is a gap, never a line.
        var hrDrawn = 0, hrs = [];
        document.querySelectorAll('hr').forEach(function (el) {
          if (!seen(el)) return;
          var cs = getComputedStyle(el);
          var line = ['Top', 'Right', 'Bottom', 'Left'].some(function (s) { return parseFloat(cs['border' + s + 'Width']) > 0 && cs['border' + s + 'Style'] !== 'none' && cs['border' + s + 'Style'] !== 'hidden'; })
            || (!/rgba\(0, 0, 0, 0\)|transparent/.test(cs.backgroundColor) && el.getBoundingClientRect().height > 0)
            || cs.backgroundImage !== 'none';
          if (line) { hrDrawn += 1; if (hrs.length < 3) hrs.push([trim(el), cs.borderTop, cs.backgroundColor, cs.height]); }
        });
        // A dictionary's own fold sign inside a fold head XDict draws a chevron for: drawn boxes holding no word.
        var foldSign = 0, signs = [];
        document.querySelectorAll('[data-xdict-control=disclosure] *').forEach(function (el) {
          if (!seen(el) || /\S/.test(el.textContent) || el.closest('[data-xdict-control=speaker],[data-xdict-role=label]') || el.matches('img,svg,[data-xdict-icon]')) return;
          var r = el.getBoundingClientRect();
          if (r.width < 2 && r.height < 2) return;
          var cs = getComputedStyle(el);
          var drawn = !/rgba\(0, 0, 0, 0\)|transparent/.test(cs.backgroundColor) || cs.backgroundImage !== 'none'
            || ['Top', 'Right', 'Bottom', 'Left'].some(function (s) { return parseFloat(cs['border' + s + 'Width']) > 0 && cs['border' + s + 'Style'] !== 'none'; });
          if (drawn) { foldSign += 1; if (signs.length < 3) signs.push(trim(el).slice(0, 150)); }
        });
        var levelPill = 0, pills = [];
        // Pills the core made labels (a level label in front of the text it replaced): reported, for review.
        var pillLabels = Array.prototype.filter.call(document.querySelectorAll('[data-xdict-label=level] + [data-xdict-labelled]'),
          function (el) { return /\S/.test(el.textContent); }).map(function (el) { return trim(el).slice(0, 120); });
        document.querySelectorAll('body *').forEach(function (el) {
          if (!seen(el) || el.closest('[data-xdict-role=label]') || !/^[abc][12]\+?$/i.test(el.textContent.trim())) return;
          var cs = getComputedStyle(el);
          var drawn = !/rgba\(0, 0, 0, 0\)|transparent/.test(cs.backgroundColor) || cs.backgroundImage !== 'none'
            || ['Top', 'Right', 'Bottom', 'Left'].some(function (s) { return parseFloat(cs['border' + s + 'Width']) > 0 && cs['border' + s + 'Style'] !== 'none'; });
          if (!drawn) return;
          levelPill += 1;
          if (pills.length < 3) pills.push([trim(el).slice(0, 150), cs.backgroundColor, cs.borderTopWidth]);
        });
        return { dotWorst: Math.round(dotWorst * 1000) / 1000, dots: dots, dotSquare: dotSquare, squares: squares,
                 heads: Array.prototype.map.call(document.querySelectorAll("[data-xdict-control=disclosure]"), function (h) { return trim(h).slice(0, 600); }).slice(0, 2), pronOff: pronOff, pronTotal: pronTotal, pron: pron,
                 labelGapOver: labelGapOver, labelGaps: labelGaps, foldGapOver: foldGapOver, folds: folds,
                 foldHeads: heads.length, spacePunct: spacePunct, punct: punct,
                 labelTight: labelTight, tight: tight, speakerTight: speakerTight, spTight: spTight, markerOff: mk[0], markers: mk[1], markerTotal: mk[2],
                 chevronOff: ch[0], chevrons: ch[1], chevronTotal: ch[2], levelPill: levelPill, pills: pills, pillLabels: pillLabels, phonFonts: Array.from(new Set(Array.prototype.map.call(document.querySelectorAll("[data-xdict-phon]"), function (e) { return getComputedStyle(e).fontFamily; }))).slice(0, 3), hrDrawn: hrDrawn, hrs: hrs, foldSign: foldSign, signs: signs };
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

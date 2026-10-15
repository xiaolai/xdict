import AppKit
import Foundation
import WebKit
import XDictEntryView

/// One sampled entry, as `entries_corpus` chose it (`XDICT_ENTRIES_SAMPLE_OUT`): the dictionary's folder, the key, which
/// record under it.
struct SampledEntry: Decodable {
    let dict: String
    let key: String
    let occurrence: UInt32
}

/// **Real dictionaries through the production entry view** (plan-macos-v1 WI-4, done-when): the sampled entries render
/// with every image and stylesheet the core resolves loaded and nothing outside `xdict:`; OALD's and LDOCE's folding
/// scripts open a section; LDOCE's *hold* renders and stays usable in a narrow window; find's count equals a count over
/// the entry's own text; zoom and appearance survive a relaunch (`--persistence set`, then `check` in a new process).
@MainActor
enum CorpusRun {
    /// What the document loaded and how, read in the lab's own world: every image and stylesheet with its state, and
    /// every URL a loadable element names that is outside the view's space.
    static let survey = """
        var own = function (u) { return /^(xdict:\\/\\/d\\/|data:|blob:|about:)/i.test(u); };
        var images = Array.from(document.images).map(function (i) {
          return [i.currentSrc || i.src || '', i.complete, i.naturalWidth];
        });
        var sheets = Array.from(document.querySelectorAll('link[rel~="stylesheet"]')).map(function (l) {
          return [l.href || '', !!l.sheet];
        });
        var outside = [];
        document.querySelectorAll('img,script,link,source,video,audio,iframe,object,embed,input,track').forEach(function (e) {
          ['src', 'href', 'data', 'poster', 'srcset'].forEach(function (a) {
            var v = e.getAttribute(a);
            if (v && e[a] !== undefined && typeof e[a] === 'string' && e[a] && !own(e[a]) && a !== 'srcset') outside.push(e.tagName + ' ' + a + ' ' + e[a]);
          });
        });
        performance.getEntriesByType('resource').forEach(function (r) { if (!own(r.name)) outside.push('loaded ' + r.name); });
        return { images: images, sheets: sheets, outside: outside, text: (document.body ? document.body.innerText.length : 0) };
        """

    static func run(options: LabOptions, core: LabCore) async throws -> [String: Any] {
        guard let root = options.fixture else { throw LabFailure(description: "--corpus needs a folder") }
        if let mode = options.persistence { return try await persistence(mode, root: root, core: core) }
        guard let samplePath = options.sample else { throw LabFailure(description: "--corpus needs --sample") }
        let sample = try JSONDecoder().decode([SampledEntry].self, from: Data(contentsOf: samplePath))
        let byDict = Dictionary(grouping: sample, by: \.dict)
        var dictionaries: [String: Any] = [:]
        var failures: [String] = []
        var rendered = 0
        for name in byDict.keys.sorted() {
            let content = try core.open(root.appending(path: name))
            let log = EventLog()
            let controller = EntryViewController(environment: environment("corpus", log: log))
            let window = labWindow(name, frame: NSRect(x: 100, y: 120, width: 900, height: 700), view: controller.view)
            var tally: [String: Int] = ["entries": 0, "images": 0, "sheets": 0, "notLoaded": 0, "outside": 0]
            for entry in byDict[name] ?? [] {
                let before = log.finishedCount
                let since = Date().timeIntervalSince1970
                guard await controller.show(EntryReference(key: entry.key, occurrence: entry.occurrence), from: content),
                      await log.waitForFinished(before + 1, seconds: 20) else {
                    failures.append("\(name) \(entry.key)/\(entry.occurrence): did not finish loading")
                    continue
                }
                guard let found = await labEvaluate(controller.webView, survey) as? [String: Any] else {
                    failures.append("\(name) \(entry.key): no survey")
                    continue
                }
                rendered += 1
                tally["entries", default: 0] += 1
                // Served 200 by the scheme handler: what the core resolved. A 404 is a resource the dictionary lacks.
                let resolved = Set(log.served(since: since).filter { $0.status == 200 }.map(\.url))
                for image in found["images"] as? [[Any]] ?? [] {
                    guard let src = image.first as? String, resolved.contains(src) else { continue }
                    tally["images", default: 0] += 1
                    if !((image[1] as? Bool ?? false) && (image[2] as? Int ?? 0) > 0) {
                        tally["notLoaded", default: 0] += 1
                        failures.append("\(name) \(entry.key): image not loaded \(src)")
                    }
                }
                for sheet in found["sheets"] as? [[Any]] ?? [] {
                    guard let href = sheet.first as? String, resolved.contains(href) else { continue }
                    tally["sheets", default: 0] += 1
                    if !(sheet[1] as? Bool ?? false) {
                        tally["notLoaded", default: 0] += 1
                        failures.append("\(name) \(entry.key): stylesheet not applied \(href)")
                    }
                }
                for outside in found["outside"] as? [String] ?? [] {
                    tally["outside", default: 0] += 1
                    failures.append("\(name) \(entry.key): outside xdict: \(outside)")
                }
            }
            dictionaries[name] = tally
            controller.closeEntry()
            window.close()
        }
        var report: [String: Any] = ["mode": "corpus", "rendered": rendered, "sampled": sample.count,
                                     "dictionaries": dictionaries, "failures": failures]
        report["folding"] = try await folding(root: root, core: core)
        report["long"] = try await long(root: root, core: core)
        return report
    }

    static func environment(_ suite: String, log: EventLog) -> EntryEnvironment {
        EntryEnvironment(preferences: EntryPreferences(defaults: UserDefaults(suiteName: "ai.xdict.lab.\(suite)") ?? .standard),
                         opener: RecordingOpener(),
                         ruleListDirectory: FileManager.default.temporaryDirectory.appending(path: "xdict-lab-rules"),
                         events: { log.note($0) })
    }

    /// R5: in OALD and LDOCE, a control the dictionary's own script handles (`toggle_active`, `toggle`, `showAtLink`) is
    /// clicked; the text the reader can see must change, and nothing may be refused or blocked meanwhile.
    static func folding(root: URL, core: LabCore) async throws -> [String: Any] {
        var out: [String: Any] = [:]
        // LDOCE folds only in its collocation boxes: `toggle(` is in no headword's record, only in the internal
        // `@collocations_N` records an entry's Collocations button links to (measured over LDOCE6.mdx, 2026-10-14).
        for (name, key) in [("oald", "run"), ("ldoce", "@collocations_1")] {
            let folder = root.appending(path: name)
            guard FileManager.default.fileExists(atPath: folder.path) else { out[name] = "absent"; continue }
            let content = try core.open(folder)
            let log = EventLog()
            let controller = EntryViewController(environment: environment("fold", log: log))
            let window = labWindow("fold \(name)", frame: NSRect(x: 100, y: 120, width: 900, height: 700), view: controller.view)
            defer { controller.closeEntry(); window.close() }
            guard await controller.show(EntryReference(key: key), from: content), await log.waitForFinished(1, seconds: 20) else {
                out[name] = ["worked": false, "why": "the entry did not load"]
                continue
            }
            try await Task.sleep(for: .milliseconds(800))
            let since = Date().timeIntervalSince1970
            let result = await labEvaluate(controller.webView, """
                var toggles = Array.from(document.querySelectorAll('[onclick]')).filter(function (e) {
                  return /toggle|showAtLink/.test(e.getAttribute('onclick'));
                });
                var tried = 0;
                for (var i = 0; i < toggles.length && i < 12; i++) {
                  var before = document.body.innerText.length;
                  toggles[i].click();
                  tried += 1;
                  var after = document.body.innerText.length;
                  if (after !== before) return { toggles: toggles.length, tried: tried, before: before, after: after };
                }
                return { toggles: toggles.length, tried: tried, before: -1, after: -1 };
                """) as? [String: Any] ?? [:]
            try await Task.sleep(for: .milliseconds(500))
            let trouble = log.events.filter { $0.time >= since }.compactMap { item -> String? in
                switch item.event {
                case .refusedRequest(_, let url, let why): "refused \(url): \(why)"
                case .served(_, let url, _, _, _) where url.contains("/blocked/"): "blocked \(url)"
                case .navigation(let url, let verdict, _, _) where !verdict.contains("allow"): "\(verdict) \(url)"
                default: nil
                }
            }
            let before = result["before"] as? Int ?? -1, after = result["after"] as? Int ?? -1
            out[name] = ["worked": before >= 0 && before != after && trouble.isEmpty, "result": result, "trouble": trouble]
        }
        return out
    }

    /// LDOCE's *hold* (625 KB): how long it takes to finish, find's count against a count over the entry's own text, and
    /// whether the window at its narrowest needs horizontal scrolling. It is asked for 360 points and stops at the
    /// entry view's own minimum (421 points, WI-6), so the width it settled at is measured and reported, never assumed.
    static func long(root: URL, core: LabCore) async throws -> [String: Any] {
        let folder = root.appending(path: "ldoce")
        guard FileManager.default.fileExists(atPath: folder.path) else { return ["absent": true] }
        let content = try core.open(folder)
        let log = EventLog()
        let controller = EntryViewController(environment: environment("long", log: log))
        let window = labWindow("hold", frame: NSRect(x: 100, y: 120, width: 900, height: 700), view: controller.view)
        defer { controller.closeEntry(); window.close() }
        let started = Date()
        guard await controller.show(EntryReference(key: "hold"), from: content), await log.waitForFinished(1, seconds: 30) else {
            return ["finished": false]
        }
        let seconds = Date().timeIntervalSince(started)
        var report: [String: Any] = ["finished": true, "seconds": seconds]
        for query in ["hold", "on", "the"] {
            let findStarted = Date()
            let found = await controller.performFind(query).value
            let expected = await labEvaluate(controller.webView, """
                var words = '\(query)'.trim().split(/\\s+/).map(function (w) { return w.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'); });
                var m = document.body.innerText.match(new RegExp(words.join('\\\\s+'), 'giu'));
                return m ? m.length : 0
                """) as? Int ?? -1
            report["find \(query)"] = ["visible": found?.visible ?? -1, "hidden": found?.hidden ?? -1,
                                       "innerText": expected, "seconds": Date().timeIntervalSince(findStarted)]
        }
        window.setContentSize(NSSize(width: 360, height: 700))
        try await Task.sleep(for: .milliseconds(800))
        var narrow = await labEvaluate(controller.webView, """
            return { scrollWidth: document.documentElement.scrollWidth, clientWidth: document.documentElement.clientWidth,
                     scrollHeight: document.documentElement.scrollHeight }
            """) as? [String: Any] ?? [:]
        narrow["windowWidth"] = Double(window.contentLayoutRect.width)
        report["narrow"] = narrow
        return report
    }

    /// Zoom and appearance per dictionary across a relaunch: `set` gives two dictionaries different values and exits;
    /// `check`, in a new process, opens both and reads what the view applied.
    static func persistence(_ mode: String, root: URL, core: LabCore) async throws -> [String: Any] {
        let names = ["oald", "ldoce"]
        var out: [String: Any] = ["mode": "persistence-\(mode)"]
        for (index, name) in names.enumerated() {
            let content = try core.open(root.appending(path: name))
            let log = EventLog()
            let controller = EntryViewController(environment: environment("persistence", log: log))
            let window = labWindow(name, frame: NSRect(x: 100, y: 120, width: 600, height: 500), view: controller.view)
            defer { controller.closeEntry(); window.close() }
            guard await controller.show(EntryReference(key: "run"), from: content), await log.waitForFinished(1, seconds: 20) else {
                out[name] = "did not load"
                continue
            }
            if mode == "set" {
                controller.setZoom(index == 0 ? 1.5 : 0.8)
                controller.setTheme(index == 0 ? .dark : .original)
            }
            try await Task.sleep(for: .milliseconds(600))
            let scheme = await labEvaluate(controller.webView, "return window.getComputedStyle(document.documentElement).colorScheme")
            out[name] = ["zoom": controller.zoom, "pageZoom": controller.webView?.pageZoom ?? -1,
                         "theme": controller.theme.rawValue, "colorScheme": scheme ?? NSNull()]
        }
        return out
    }
}

import AppKit
import Foundation
import WebKit
import XDictClient
import XDictContract
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictUI
import XDictTokens

/// `XDict --entry-corpus <corpus> --library-dir <dir> --sample <sample.json> --out <file>`, then `--persistence set` and
/// `--persistence check` (each a launch of its own): a development instrument for the E2E `entries` stage (run on the E2E
/// Mac only). **The owner's dictionaries through the app's own window** (plan-macos-v1 WI-4's stamp, re-measured at
/// WI-6): the corpus's folders added to a library of the instrument's (an edition the service has indexed before is only
/// hashed), each sampled entry reached as a link to it is — looked up in link mode in its dictionary by the window's
/// model — and shown by the window's entry view, then read as the lab reads it. The report has the lab's shape, so
/// `Tools/hostile/analyze.py entries` holds it to the same rules: every image and stylesheet the core resolved loaded and
/// nothing outside `xdict:`; OALD's and LDOCE's folding scripts open a section; LDOCE's *hold* finishes, find counts
/// what its text holds, and a 360-point entry needs no horizontal scrolling; zoom and appearance survive a relaunch.
enum AppCorpusReport {
    static let flag = "--entry-corpus"
    static let persistenceSuite = "ai.xdict.app.e2e.persistence"

    struct Sampled: Decodable {
        let dict: String
        let key: String
        let occurrence: UInt32
    }

    @MainActor
    static func run(_ arguments: [String]) -> Never {
        let usage = "\(flag) <corpus> --library-dir <dir> (--sample <json> | --persistence set|check) --out <file>"
        guard let corpus = Instrument.value(after: flag, in: arguments).map(URL.init(fileURLWithPath:)),
              let directory = Instrument.value(after: "--library-dir", in: arguments).map(URL.init(fileURLWithPath:)),
              let out = Instrument.value(after: "--out", in: arguments).map(URL.init(fileURLWithPath:)) else {
            FileHandle.standardError.write(Data("usage: \(usage)\n".utf8))
            exit(2)
        }
        let persistence = Instrument.value(after: "--persistence", in: arguments)
        var sample: [Sampled] = []
        if persistence == nil {
            guard let file = Instrument.value(after: "--sample", in: arguments),
                  let data = FileManager.default.contents(atPath: file),
                  let decoded = try? JSONDecoder().decode([Sampled].self, from: data) else {
                FileHandle.standardError.write(Data("usage: \(usage)\n".utf8))
                exit(2)
            }
            sample = decoded
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            let names = Set(sample.map(\.dict)).union(["oald", "ldoce"]).sorted()
                .filter { FileManager.default.fileExists(atPath: corpus.appending(path: $0).path) }
            let client = ServiceClient()
            let began = ContinuousClock.now
            let (library, settled) = await instrumentLibrary(directory, client: client,
                                                             adding: names.map { corpus.appending(path: $0) },
                                                             within: .seconds(3_600))
            let run = AppCorpusRun(library: library, client: client, corpus: corpus)
            var report: [String: Any]
            if let persistence {
                report = await run.persistence(persistence)
            } else {
                report = await run.sample(sample)
                report["folding"] = await run.folding()
                report["long"] = await run.long()
            }
            report["path"] = "app"
            report["librarySettled"] = settled
            report["librarySeconds"] = Double((ContinuousClock.now - began).components.seconds)
            do {
                try writeReport(report, to: out)
            } catch {
                FileHandle.standardError.write(Data("the report could not be written: \(error)\n".utf8))
                exit(1)
            }
            exit(0)
        }
        app.run()
        exit(1)
    }
}

/// The corpus's checks, each through a main window of its own.
@MainActor
final class AppCorpusRun {
    /// As the lab reads a document (`Sources/XDictEntryLab/Corpus.swift`'s `survey`): every image and stylesheet with
    /// its state, and every URL a loadable element names outside the view's space.
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

    let library: Library
    let client: ServiceClient
    let corpus: URL

    init(library: Library, client: ServiceClient, corpus: URL) {
        self.library = library
        self.client = client
        self.corpus = corpus
    }

    /// The library's dictionary in the corpus folder `name`.
    func source(_ name: String) -> SearchSource? {
        let folder = corpus.appending(path: name).resolvingSymlinksInPath().path + "/"
        guard let entry = library.entries.first(where: { $0.mdx?.location.path.hasPrefix(folder) == true }) else { return nil }
        return library.searchSources.first { $0.id == entry.id && $0.handle != nil }
    }

    func window(_ title: String, width: Double = 900, height: Double = 700, suite: String = "ai.xdict.app.e2e.entries")
        -> InstrumentWindow {
        InstrumentWindow(title, frame: NSRect(origin: Tokens.InstrumentFrame.corpusOrigin.origin, size: CGSize(width: width, height: height)), library: library,
                         backend: client, suite: suite, opener: RecordingOpener())
    }

    /// `key`, reached in `source` as a link to it is, then the record `occurrence` of it where a key has several: the
    /// entry shown and loaded, or nil.
    func reach(_ key: String, occurrence: UInt32 = 0, in source: SearchSource, by window: InstrumentWindow) async
        -> SearchModel.Shown? {
        let model = window.state.model
        model.follow(key, anchor: nil, from: source.id)
        await model.idle()
        await model.answersSettled()
        if occurrence > 0 {
            // A later record of the key: chosen among the results as a reader would, page after page until it is there.
            var hit: Hit?
            while hit == nil, case .results(let results)? = model.sections.first(where: { $0.id == source.id })?.status {
                hit = results.hits.first { $0.entry.key == key && $0.entry.occurrence == occurrence }
                guard hit == nil, results.hasMore else { break }
                model.loadMore(source.id)
                await model.answersSettled()
            }
            guard let hit else { return nil }
            model.select(ResultID(dictionary: source.id, entry: hit.entry))
        }
        // Found, and chosen: else the entry on screen is the one before, and this one was not reached.
        guard model.lookup?.query == key, let chosen = model.selection, model.shown?.result == chosen else { return nil }
        return await window.shownAndLoaded(within: .seconds(20))
    }

    func sample(_ sample: [AppCorpusReport.Sampled]) async -> [String: Any] {
        let byDict = Dictionary(grouping: sample, by: \.dict)
        var dictionaries: [String: Any] = [:]
        var failures: [String] = []
        var rendered = 0
        for name in byDict.keys.sorted() {
            guard let source = source(name) else {
                failures.append("\(name): not in the library, or not answering")
                continue
            }
            let window = window(name)
            var tally: [String: Int] = ["entries": 0, "images": 0, "sheets": 0, "notLoaded": 0, "outside": 0]
            for entry in byDict[name] ?? [] {
                let since = Date().timeIntervalSince1970
                guard await reach(entry.key, occurrence: entry.occurrence, in: source, by: window) != nil else {
                    failures.append("\(name) \(entry.key)/\(entry.occurrence): not reached, or did not finish loading")
                    continue
                }
                guard let found = await InstrumentPage.evaluate(window.state.entry.webView, Self.survey) as? [String: Any] else {
                    failures.append("\(name) \(entry.key): no survey")
                    continue
                }
                rendered += 1
                tally["entries", default: 0] += 1
                let resolved = Set(window.log.served(since: since).filter { $0.status == 200 }.map(\.url))
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
            window.close()
        }
        return ["mode": "corpus", "rendered": rendered, "sampled": sample.count, "dictionaries": dictionaries,
                "failures": failures]
    }

    /// R5, as the lab checks it: a control the dictionary's own script handles is clicked, and the text the reader can
    /// see changes, with nothing refused or blocked meanwhile. LDOCE folds only in its `@collocations_N` boxes, which
    /// a link reaches.
    func folding() async -> [String: Any] {
        var out: [String: Any] = [:]
        for (name, key) in [("oald", "run"), ("ldoce", "@collocations_1")] {
            guard let source = source(name) else {
                out[name] = "absent"
                continue
            }
            let window = window("fold \(name)")
            defer { window.close() }
            guard await reach(key, in: source, by: window) != nil else {
                out[name] = ["worked": false, "why": "the entry did not load"]
                continue
            }
            try? await Task.sleep(for: .milliseconds(800))
            let since = Date().timeIntervalSince1970
            let result = await InstrumentPage.evaluate(window.state.entry.webView, """
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
            try? await Task.sleep(for: .milliseconds(500))
            let trouble = window.log.events.filter { $0.time >= since }.compactMap { item -> String? in
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

    /// LDOCE's *hold*: how long it takes from the link to a finished document, find's count against a count over the
    /// entry's own text, and whether the entry at 360 points wide needs horizontal scrolling.
    func long() async -> [String: Any] {
        guard let source = source("ldoce") else { return ["absent": true] }
        let window = window("hold")
        defer { window.close() }
        let started = Date()
        guard await reach("hold", in: source, by: window) != nil else { return ["finished": false] }
        var report: [String: Any] = ["finished": true, "seconds": Date().timeIntervalSince(started)]
        let entry = window.state.entry
        for query in ["hold", "on", "the"] {
            let findStarted = Date()
            let found = await entry.performFind(query).value
            let expected = await InstrumentPage.evaluate(entry.webView, """
                var words = '\(query)'.trim().split(/\\s+/).map(function (w) { return w.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'); });
                var m = document.body.innerText.match(new RegExp(words.join('\\\\s+'), 'giu'));
                return m ? m.length : 0
                """) as? Int ?? -1
            report["find \(query)"] = ["visible": found?.visible ?? -1, "hidden": found?.hidden ?? -1,
                                       "innerText": expected, "seconds": Date().timeIntervalSince(findStarted)]
        }
        // The window narrowed until the entry itself is 360 points wide, its sidebar as the reader left it.
        let entryWidth = entry.view.frame.width
        let size = window.window.contentLayoutRect.size
        window.window.setContentSize(NSSize(width: max(size.width - (entryWidth - Tokens.InstrumentSize.narrowPane.width), Tokens.InstrumentSize.narrowPane.width),
                                                height: size.height))
        try? await Task.sleep(for: .milliseconds(800))
        var narrow = await InstrumentPage.evaluate(entry.webView, """
            return { scrollWidth: document.documentElement.scrollWidth, clientWidth: document.documentElement.clientWidth,
                     scrollHeight: document.documentElement.scrollHeight }
            """) as? [String: Any] ?? [:]
        narrow["entryPoints"] = entry.view.frame.width
        // The width the window settled at, which `analyze.py entries` requires as the lab reports it: without it the
        // narrow check failed as "its width not reported" whatever the entry did (found 2026-10-15).
        narrow["windowWidth"] = Double(window.window.contentLayoutRect.width)
        report["narrow"] = narrow
        return report
    }

    /// Zoom and appearance per dictionary across a relaunch: `set` gives two dictionaries different values and exits;
    /// `check`, in a new process, opens both and reads what the view applied.
    func persistence(_ mode: String) async -> [String: Any] {
        var out: [String: Any] = ["mode": "persistence-\(mode)"]
        for (index, name) in ["oald", "ldoce"].enumerated() {
            guard let source = source(name) else {
                out[name] = "absent"
                continue
            }
            let window = window(name, width: 600, height: 500, suite: AppCorpusReport.persistenceSuite)
            defer { window.close() }
            guard await reach("run", in: source, by: window) != nil else {
                out[name] = "did not load"
                continue
            }
            let entry = window.state.entry
            if mode == "set" {
                entry.setZoom(index == 0 ? 1.5 : 0.8)
                entry.setTheme(index == 0 ? .dark : .original)
            }
            try? await Task.sleep(for: .milliseconds(600))
            let scheme = await InstrumentPage.evaluate(entry.webView,
                                                       "return window.getComputedStyle(document.documentElement).colorScheme")
            out[name] = ["zoom": entry.zoom, "pageZoom": entry.webView?.pageZoom ?? -1, "theme": entry.theme.rawValue,
                         "colorScheme": scheme ?? NSNull()]
        }
        return out
    }
}

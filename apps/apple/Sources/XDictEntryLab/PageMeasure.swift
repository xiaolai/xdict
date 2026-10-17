import AppKit
import Foundation
import WebKit
import XDictCore
import XDictEntryView

/// **The All page's first paint** (Apple parity P15; ADR-0010 amendment of 2026-10-18): every dictionary folder under
/// `--page <dir>` opened, each word looked up in all of them, and the production entry view's page shown in a 900 × 700
/// window with one frame per dictionary that has the word. Measured per word: the time to the first frame's document
/// loaded (first paint), the time until every frame made has loaded, how many frames were made of how many, and the
/// same with every frame made at once (as find makes them), against one dictionary's entry alone.
@MainActor
enum PageMeasure {
    static func run(options: LabOptions, core: LabCore) async throws -> [String: Any] {
        guard let root = options.fixture else { throw LabFailure(description: "--page needs a folder") }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var opened: [CoreContent] = []
        var failures: [String] = []
        for folder in folders {
            do { opened.append(try core.open(folder)) } catch { failures.append("\(folder.lastPathComponent): \(error)") }
        }
        var words: [[String: Any]] = []
        for word in options.only.isEmpty ? ["set", "run", "take", "apple", "good"] : options.only.sorted() {
            var items: [EntryPageItem] = []
            for content in opened {
                let page = try? core.core.lookup(query: word, dicts: [content.binding.handle],
                                                 options: LookupOptions(limit: 1, offset: 0, mode: .reader, generation: nil))
                guard let hit = page?.hits.first else { continue }
                items.append(EntryPageItem(id: UUID(), name: content.title, content: content,
                                           reference: EntryReference(key: hit.entry.key, occurrence: hit.entry.occurrence)))
            }
            guard !items.isEmpty else { continue }
            var row: [String: Any] = ["word": word, "dictionaries": items.count]
            row["single"] = await single(items[0])
            row["lazy"] = await page(items, all: false)
            row["all"] = await page(items, all: true)
            words.append(row)
        }
        return ["mode": "page", "dictionaries": opened.count, "words": words, "failures": failures]
    }

    private static func environment() -> EntryEnvironment {
        EntryEnvironment(preferences: EntryPreferences(defaults: UserDefaults(suiteName: "ai.xdict.lab.page") ?? .standard),
                         opener: RecordingOpener(),
                         ruleListDirectory: FileManager.default.temporaryDirectory.appending(path: "xdict-lab-rules"))
    }

    private static func ms(_ duration: Duration) -> Double {
        let (s, a) = duration.components
        return (Double(s) * 1_000 + Double(a) / 1e15).rounded()
    }

    /// One dictionary's entry, as a single entry view shows it: the baseline.
    private static func single(_ item: EntryPageItem) async -> [String: Any] {
        let log = EventLog()
        var environment = environment()
        environment.events = { log.note($0) }
        let controller = EntryViewController(environment: environment)
        let window = labWindow("single", frame: NSRect(x: 100, y: 120, width: 900, height: 700), view: controller.view)
        defer {
            controller.closeEntry()
            window.close()
        }
        let start = ContinuousClock.now
        let before = log.finishedCount
        guard await controller.show(item.reference, from: item.content), await log.waitForFinished(before + 1, seconds: 20)
        else { return ["failed": true] }
        return ["firstPaintMs": ms(.now - start)]
    }

    /// The page, lazily (the screen and one beyond) or with every frame made at once.
    private static func page(_ items: [EntryPageItem], all: Bool) async -> [String: Any] {
        let controller = EntryViewController(environment: environment())
        let window = labWindow("page", frame: NSRect(x: 100, y: 120, width: 900, height: 700), view: controller.view)
        defer {
            controller.closeEntry()
            window.close()
        }
        let start = ContinuousClock.now
        guard await controller.showPage(items, primary: items[0].id) else { return ["failed": true] }
        if all { controller.performFind("\u{1}") }
        let deadline = ContinuousClock.now + .seconds(60)
        while controller.pageFirstPaint == nil || !controller.pageLoaded
                || (all && (controller.pageFrames?.made ?? 0) < items.count), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let settled = ContinuousClock.now - start
        // Every frame's height is its document's: a frame never scrolls inside.
        var inner: [String] = []
        for (index, webView) in controller.pageWebViews.enumerated() {
            let fits = try? await webView.callAsyncJavaScript(
                "return [document.documentElement.scrollHeight, window.innerHeight, document.documentElement.getBoundingClientRect().height]", arguments: [:], in: nil,
                contentWorld: HostileRun.labWorld) as? [Double]
            // Past the page's cap a frame scrolls inside by design (`EntryPage.maximumFrameHeight`).
            if let fits, fits.count == 3, fits[0] > fits[1] + 1, fits[0] * controller.zoom <= 200_000 {
                inner.append("frame \(index): scrollHeight \(fits[0]), frame \(fits[1]), root \(fits[2])")
            }
        }
        var out: [String: Any] = [
            "firstPaintMs": controller.pageFirstPaint.map(ms) ?? -1, "settledMs": ms(settled),
            "made": controller.pageFrames?.made ?? 0, "of": controller.pageFrames?.of ?? 0,
            "framesScrollingInside": inner,
        ]
        if all, controller.pageWebViews.count >= 2 { out["isolation"] = await isolation(controller.pageWebViews) }
        return out
    }

    /// **Whether one frame can reach another** through what same-origin pages share: storage, a broadcast channel, and
    /// CSS. Every frame is `xdict://d/`, so only their separate data stores and processes keep them apart. The first
    /// frame writes, the second reads; the same writes read back in the first frame are the positive control (the
    /// channel and the storage work at all).
    private static func isolation(_ frames: [WKWebView]) async -> [String: Any] {
        func run(_ view: WKWebView, _ body: String) async -> Any? {
            do {
                return try await view.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: HostileRun.labWorld)
            } catch {
                return "error: \(error.localizedDescription)"
            }
        }
        let listen = """
            window.__iso = []; window.__isoChannel = new BroadcastChannel("xdict-iso");
            window.__isoChannel.onmessage = (e) => window.__iso.push(e.data); return true;
            """
        let (a, b) = (frames[0], frames[1])
        _ = await run(b, listen)
        _ = await run(a, listen)
        let wrote = await run(a, """
            let stored = "no";
            try { localStorage.setItem("xdict-iso", "a"); stored = localStorage.getItem("xdict-iso"); }
            catch (e) { stored = "error: " + e.name; }
            new BroadcastChannel("xdict-iso").postMessage("from-a");
            return stored;
            """)
        try? await Task.sleep(for: .milliseconds(500))
        let read = """
            let stored;
            try { stored = localStorage.getItem("xdict-iso"); } catch (e) { stored = "error: " + e.name; }
            const p = document.querySelector("p"), bold = document.querySelector("b");
            return { stored: stored, heard: window.__iso.length,
                     pColour: p ? getComputedStyle(p).color : null,
                     bSpacing: bold ? getComputedStyle(bold).letterSpacing : null };
            """
        return ["firstWroteAndReadBack": wrote ?? "nil", "first": await run(a, read) ?? "nil",
                "second": await run(b, read) ?? "nil"]
    }
}

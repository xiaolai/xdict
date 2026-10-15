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
    }

    /// The views the merged tree can render. "before" and "after" (frame only) need a core without normalization, so
    /// a run of the merged tree renders the frame + core views and reuses an earlier report's entries (`--keys`).
    static let modes = [Mode(name: "core-light", frame: .all, theme: .original),
                        Mode(name: "core-dark", frame: .all, theme: .dark),
                        Mode(name: "coreserif-light", frame: [.column, .type, .serif], theme: .original),
                        Mode(name: "coreserif-dark", frame: [.column, .type, .serif], theme: .dark)]

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
            for mode in modes {
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
                    if !mode.frame.isEmpty, let stray = measured?["nonToken"] as? [[Any]], !stray.isEmpty {
                        failures.append("\(name) \(mode.name) \(entry.key): text colours outside the palette \(stray)")
                    }
                    if let webView = controller.webView, let image = try? await webView.takeSnapshot(configuration: nil),
                       let data = jpeg(image) {
                        try data.write(to: images.appending(path: file))
                    } else {
                        failures.append("\(name) \(mode.name) \(entry.key): no snapshot")
                    }
                    rows.append(["dict": name, "kind": kind, "key": entry.key, "mode": mode.name, "image": "images/\(file)",
                                 "measure": measured ?? NSNull()])
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

    static func jpeg(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

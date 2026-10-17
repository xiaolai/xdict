import AppKit
import WebKit
import XDictClient
import XDictContract
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictUI

/// `XDict --measure <work> --corpus <dir>`: the WI-10 measurement instrument (plan-macos-v1 WI-10, "Measurement
/// protocol"; on the E2E Mac only, when the owner runs `make e2e-quick STAGES=measure.protocol`). **The real app** —
/// its main window, its service, its panel — over a library of its own in `<work>/store` holding every dictionary folder in
/// `<dir>` (the 24). The keys are the driver's (`Tools/measure/drive.py`, real key events); this says when they came and
/// when WebKit painted what they asked for.
///
/// One sample: the Return key's event in the main window (its own `NSEvent.timestamp`, the time the key event was made,
/// as wall-clock seconds) to WebKit's first paint of the entry that Return showed (the Paint Timing API's
/// `first-contentful-paint`, WebKit's own record of that paint, read afterwards from a content world of its own, so the
/// reading adds nothing to the time measured). A document begun before the key is not the one it asked for: such a
/// sample is written `stale`, never timed. **Harness overhead**: the time this instrument's own observers (its key
/// monitor and its entry-event hook, both on the main thread inside the interval) spent between the key and the paint,
/// timed by `ContinuousClock` and written beside each sample, for the analysis to subtract (`Tools/measure/stats.py`).
///
/// Writes `<work>/ready.json` once the library has settled, then one line of `<work>/samples.jsonl` per Return; answers
/// `<work>/commands/NNN.json` (`state`, `front`, `quit`) in `NNN.out.json`.
enum MeasureReport {
    static let flag = "--measure"

    static func setup(_ arguments: [String]) -> AppSetup? {
        guard let work = Instrument.value(after: flag, in: arguments) else { return nil }
        return AppSetup(libraryDirectory: URL(fileURLWithPath: work).appending(path: "store"), service: ServiceClient(),
                        entryEvents: { event in MeasureRun.shared?.note(event) },
                        speechVolume: 0, speechSuite: InstrumentWindow.speechSuite)
    }

    @MainActor
    static func prepare(_ arguments: [String]) {
        guard let work = Instrument.value(after: flag, in: arguments).map(URL.init(fileURLWithPath:)),
              let corpus = Instrument.value(after: "--corpus", in: arguments).map(URL.init(fileURLWithPath:)) else {
            FileHandle.standardError.write(Data("usage: \(flag) <work> --corpus <dir>\n".utf8))
            exit(2)
        }
        let run = MeasureRun(work: work, corpus: corpus)
        MeasureRun.shared = run
        XDictApp.windowMade = { state in run.windowMade(state) }
    }
}

@MainActor
final class MeasureRun {
    static var shared: MeasureRun?
    static let world = WKContentWorld.world(name: "xdict-measure")
    static let returnKey: UInt16 = 36
    /// How long WebKit is given to report the paint after the document finished.
    static let paintWait = 3.0

    let work: URL
    let corpus: URL
    private var state: SearchWindowState?
    private var answered: Set<String> = []
    private var commands: URL { work.appending(path: "commands") }
    /// The Return being measured: its time, the query it submitted, the overhead so far, whether its document began.
    private var pending: (key: Double, query: String, requested: Bool)?
    private var overhead: Duration = .zero
    private var serial = 0

    init(work: URL, corpus: URL) {
        self.work = work
        self.corpus = corpus
    }

    /// Wall-clock seconds of an event's `timestamp` (seconds since boot, the time the event was made).
    static func wallClock(ofUptime uptime: TimeInterval) -> Double {
        Date().timeIntervalSince1970 - (ProcessInfo.processInfo.systemUptime - uptime)
    }

    func windowMade(_ made: SearchWindowState) {
        guard state == nil else { return }
        state = made
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let began = ContinuousClock.now
            if event.keyCode == Self.returnKey, event.window != nil, event.window === made.entry.view.window {
                pending = (Self.wallClock(ofUptime: event.timestamp), made.model.text, false)
                overhead = .zero
            }
            if pending != nil { overhead += ContinuousClock.now - began }
            return event
        }
        Task { await self.begin() }
    }

    func note(_ event: EntryEvent) {
        let began = ContinuousClock.now
        defer { if pending != nil { overhead += ContinuousClock.now - began } }
        guard let sample = pending else { return }
        switch event {
        case .documentRequested:
            pending?.requested = true
        case .documentFinished where sample.requested:
            pending = nil
            let spent = overhead
            Task { await self.finish(sample.key, sample.query, overhead: spent) }
        default:
            break
        }
    }

    private func finish(_ key: Double, _ query: String, overhead spent: Duration) async {
        serial += 1
        var line: [String: Any] = ["serial": serial, "query": query, "keyAt": key,
                                   "overheadSeconds": Double(spent.components.attoseconds) / 1e18
                                       + Double(spent.components.seconds)]
        if let shown = state?.model.shown {
            line["key"] = shown.result.entry.key
            line["dictionary"] = state?.model.source(shown.result.dictionary)?.name ?? "?"
        }
        if let paint = await paintTime() {
            line["documentAt"] = paint.origin
            line["paintAt"] = paint.at as Any
            line["stale"] = paint.origin < key
        } else {
            line["paintAt"] = NSNull()
            line["error"] = "WebKit reported no first-contentful-paint"
        }
        append(line, to: work.appending(path: "samples.jsonl"))
    }

    /// The shown document's start and its first paint, as wall-clock seconds; nil when the page could not be read.
    private func paintTime() async -> (origin: Double, at: Double?)? {
        guard let webView = state?.entry.webView else { return nil }
        let script = """
            const find = (list) => list.find((e) => e.name === "first-contentful-paint");
            let entry = find(performance.getEntriesByType("paint"));
            if (!entry) {
              entry = await new Promise((resolve) => {
                const observer = new PerformanceObserver((l) => {
                  const f = find(l.getEntries()); if (f) { observer.disconnect(); resolve(f); }
                });
                observer.observe({ type: "paint", buffered: true });
                setTimeout(() => resolve(null), \(Int(Self.paintWait * 1000)));
              });
            }
            return { origin: performance.timeOrigin, paint: entry ? entry.startTime : -1 };
            """
        guard let read = try? await webView.callAsyncJavaScript(script, contentWorld: Self.world) as? [String: Any],
              let origin = read["origin"] as? Double, let paint = read["paint"] as? Double else { return nil }
        return (origin / 1000, paint < 0 ? nil : (origin + paint) / 1000)
    }

    private func begin() async {
        try? FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        await LibraryLaunch.once()
        let library = XDictApp.library
        let have = Set(library.entries.compactMap { $0.mdx?.location.path })
        let listed = try? FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: [.isDirectoryKey])
        let folders = (listed ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.resolvingSymlinksInPath() }
            .filter { folder in !have.contains { $0.hasPrefix(folder.path + "/") } }
        if !folders.isEmpty { _ = library.add(folders) }
        let settled = await library.settled(within: .seconds(900))
        state?.model.sourcesDidChange()
        try? writeReport(["pid": Int(getpid()), "settled": settled, "dictionaries": library.searchSources.map(\.name)],
                         to: commands.appending(path: "ready.json"))
        while true {
            serve()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func serve() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: commands.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".json") && !name.contains(".out.") && name != "ready.json"
            && !answered.contains(name) {
            answered.insert(name)
            guard let data = FileManager.default.contents(atPath: commands.appending(path: name).path),
                  let asked = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let op = asked["op"] as? String else { continue }
            let out = commands.appending(path: name.replacingOccurrences(of: ".json", with: ".out.json"))
            switch op {
            case "state":
                let window = state?.entry.view.window
                try? writeReport(["pid": Int(getpid()), "active": NSApp.isActive, "key": window?.isKeyWindow == true,
                                  "text": state?.model.text ?? "", "samples": serial], to: out)
            case "front":
                NSApp.activate()
                state?.entry.view.window?.makeKeyAndOrderFront(nil)
                state?.focusSearch()
                try? writeReport(["asked": true], to: out)
            case "quit":
                try? writeReport(["quitting": true], to: out)
                exit(0)
            default:
                try? writeReport(["error": "no op \(op)"], to: out)
            }
        }
    }

    private func append(_ line: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }
}

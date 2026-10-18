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

/// `XDict --entry-hostile <library-dir> --fixture <hostile> --cases <cases.json> --out <report.json> [--concurrency N]`:
/// a development instrument for the E2E `hostile` stage (run on the E2E Mac only). **The hostile-input suite through the
/// app's own window** (plan-macos-v1 WI-4's stamp, re-measured at WI-6): the battery's dictionary added to a library of
/// the instrument's, through the app's own service; every case looked up as a reader types it, in a main window of its
/// own (`InstrumentWindow`, the production `SearchWindow`), and shown by that window's entry view in the production
/// confinement. What the view saw is recorded per case in the lab's report shape (`Tools/hostile/analyze.py run` reads
/// it); what left the machine is the observers' to say (`Tools/lookup/run-app-hostile.sh`).
enum AppHostileReport {
    static let flag = "--entry-hostile"

    struct Case: Decodable {
        let id: String
        let wait: Int
        let exclusive: Bool
        let tcp: Int
        let udp: Int
        let names: [String]
        /// Lab-world JavaScript that returns `[[key, value]]` (`Tools/hostile/battery.py`); empty for most cases.
        let probe: String
        /// Script elements in the case's record as a browser builds them; the run compares the loaded document's own
        /// `document.scripts` (its `scripts` report) to say whether the core removed any (stripped).
        let scripts: Int

        /// What the lab reads of the page, from a content world of its own, every 100 ms: the page's own reports
        /// (`data-lab`, the battery's `R()`, which only a page whose scripts run can write), that the document loaded,
        /// and the case's `probe`, which judges what must work (an image drawn, a sheet applied) without any page
        /// script, so it holds when the core's strip has removed them.
        var readScript: String {
            "var d=document.documentElement;if(!d)return null;var a;try{a=JSON.parse(d.getAttribute('data-lab')||'[]')}"
                + "catch(e){a=[['data-lab-unreadable',String(e)]]}"
                + "if(document.readyState!=='loading'&&location.href!=='about:blank')"
                + "{a.push(['loaded',document.readyState]);"
                + "a.push(['scripts',document.scripts.length])}"
                + "try{var r=(function(){\(probe);return []})()||[];a=a.concat(r)}"
                + "catch(e){a.push(['probe-throw',String(e)])}return JSON.stringify(a)"
        }

        func isLive(in html: String) -> Bool {
            html.contains("127.0.0.1:\(tcp)") || html.contains("127.0.0.1:\(udp)") || names.contains { html.contains($0) }
        }
    }

    struct Cases: Decodable {
        let cases: [Case]
    }

    @MainActor
    static func run(_ arguments: [String]) -> Never {
        guard let directory = Instrument.value(after: flag, in: arguments).map(URL.init(fileURLWithPath:)),
              let fixture = Instrument.value(after: "--fixture", in: arguments).map(URL.init(fileURLWithPath:)),
              let casesFile = Instrument.value(after: "--cases", in: arguments),
              let out = Instrument.value(after: "--out", in: arguments).map(URL.init(fileURLWithPath:)),
              let data = FileManager.default.contents(atPath: casesFile),
              let cases = try? JSONDecoder().decode(Cases.self, from: data) else {
            FileHandle.standardError.write(Data("usage: \(flag) <library-dir> --fixture <dir> --cases <json> --out <file>\n".utf8))
            exit(2)
        }
        let concurrency = Instrument.value(after: "--concurrency", in: arguments).flatMap(Int.init).map { max(1, $0) } ?? 4
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            let client = ServiceClient()
            let (library, settled) = await instrumentLibrary(directory, client: client, adding: [fixture],
                                                             within: .seconds(300))
            guard settled, let source = library.searchSources.first(where: { $0.handle != nil }) else {
                FileHandle.standardError.write(Data("the battery's dictionary did not open: \(library.phases)\n".utf8))
                exit(1)
            }
            AppHostileRun(library: library, client: client, source: source, cases: cases.cases, out: out,
                          concurrency: concurrency).start()
        }
        app.run()
        exit(1)
    }
}

/// The battery's run: up to `concurrency` cases at once, an exclusive one alone, each in a window of its own.
@MainActor
final class AppHostileRun {
    private let library: Library
    private let client: ServiceClient
    private let source: SearchSource
    private let out: URL
    private let concurrency: Int
    private var queue: [AppHostileReport.Case]
    private var running = 0
    private var exclusiveRunning = false
    private let opener = RecordingOpener()
    private var records: [String: [String: Any]] = [:]
    private var pages: [String: [[String]]] = [:]
    /// Each case's `readScript`, by id.
    private var readScripts: [String: String] = [:]
    private var windows: [String: InstrumentWindow] = [:]
    private var switches: [String: Bool]?

    init(library: Library, client: ServiceClient, source: SearchSource, cases: [AppHostileReport.Case], out: URL,
         concurrency: Int) {
        self.library = library
        self.client = client
        self.source = source
        self.queue = cases
        self.out = out
        self.concurrency = concurrency
    }

    func start() {
        pump()
    }

    private func pump() {
        while let next = queue.first, !exclusiveRunning, running < concurrency {
            if next.exclusive, running > 0 { break }
            queue.removeFirst()
            running += 1
            if next.exclusive { exclusiveRunning = true }
            launch(next, slot: running - 1)
        }
        if running == 0, queue.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.finish()
            }
        }
    }

    private func launch(_ test: AppHostileReport.Case, slot: Int) {
        let perRow = 2, tile = Tokens.InstrumentFrame.appHostileTile
        let frame = NSRect(x: tile.minX + CGFloat(slot % perRow) * Tokens.InstrumentLength.appHostileStrideX,
                           y: tile.minY + CGFloat(slot / perRow) * Tokens.InstrumentLength.appHostileStrideY,
                           width: tile.width, height: tile.height)
        let window = InstrumentWindow(test.id, frame: frame, library: library, backend: client,
                                      suite: "ai.xdict.app.e2e.hostile", opener: opener)
        windows[test.id] = window
        records[test.id] = ["start": Date().timeIntervalSince1970]
        readScripts[test.id] = test.readScript
        let source = source, client = client
        Task {
            // What the core rewrote, as the service gives it to the window.
            let content = ServiceEntryContent(source: source, backend: client)
            let rendered = try? await content?.entry(EntryReference(key: test.id))
            records[test.id]?["entryHoldsLiveTarget"] = rendered.map { test.isLive(in: String(decoding: $0.html, as: UTF8.self)) }
                ?? NSNull()
            records[test.id]?["scriptsWritten"] = test.scripts
            if test.id.hasSuffix("~resource"), case .found(_, let bytes)? = try? await content?.resource("\(test.id)/doc.html") {
                records[test.id]?["resourceHoldsLiveTarget"] = test.isLive(in: String(decoding: bytes, as: UTF8.self))
            }
            // The window's own path: the case's key, looked up as a reader types it, in the battery's dictionary.
            window.state.model.setScope(.one(source.id))
            window.state.model.submit(test.id)
            // Shown: handed to the window's entry view. Whether the page loaded is its own report (`loaded`), as in the
            // lab, where a page with media (`hls`) is reported loaded while WebKit has not finished it.
            let shown = await window.handedOver(within: .milliseconds(test.wait))
            records[test.id]?["shown"] = shown?.result.entry.key == test.id
            if switches == nil, !window.state.entry.switchesReadBack.isEmpty { switches = window.state.entry.switchesReadBack }
        }
        poll(test.id, until: Date().addingTimeInterval(Double(test.wait) / 1000))
        Task {
            try? await Task.sleep(for: .milliseconds(test.wait))
            self.end(test)
        }
    }

    /// The page's own reports (`data-lab`, the battery's `R()`), read every 100 ms while the case runs: a page that
    /// navigates away takes its reports with it.
    private func poll(_ id: String, until deadline: Date) {
        Task {
            while Date() < deadline {
                if let webView = windows[id]?.state.entry.webView { await read(id, from: webView) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func read(_ id: String, from webView: WKWebView) async {
        guard let script = readScripts[id] else { return }
        guard let value = await InstrumentPage.evaluate(webView, script) as? String, let data = value.data(using: .utf8),
              let reports = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return }
        var seen = pages[id] ?? []
        for report in reports {
            let pair = report.map { "\($0)" }
            if !seen.contains(pair) { seen.append(pair) }
        }
        pages[id] = seen
    }

    private func end(_ test: AppHostileReport.Case) {
        let window = windows[test.id]
        Task {
            if let webView = window?.state.entry.webView { await read(test.id, from: webView) }
            var record = records[test.id] ?? [:]
            let entry = window?.state.entry
            record["end"] = Date().timeIntervalSince1970
            record["events"] = window?.log.described ?? []
            record["page"] = pages[test.id] ?? []
            record["loaded"] = (pages[test.id] ?? []).contains { $0.first == "loaded" }
            record["documentFinished"] = window?.log.events.contains { if case .documentFinished = $0.event { true } else { false } }
                ?? false
            record["finalURL"] = entry?.webView?.url?.absoluteString ?? ""
            record["refusal"] = entry?.refusal.map { String(describing: $0) } ?? NSNull()
            if let webView = entry?.webView {
                record["networkPid"] = InstrumentPage.pid(webView, "_networkProcessIdentifier")
                record["webPid"] = InstrumentPage.pid(webView, "_webProcessIdentifier")
            }
            records[test.id] = record
            window?.close()
            windows[test.id] = nil
            running -= 1
            if test.exclusive { exclusiveRunning = false }
            pump()
        }
    }

    private func finish() {
        let confinement = EntryConfinement.production
        let report: [String: Any] = [
            "mode": "hostile", "path": "app", "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "webkit": InstrumentPage.webKitVersion,
            "disabled": [String](),
            "confinement": [
                "production": confinement.isProduction, "policyHeader": confinement.policyHeader,
                "ruleList": confinement.ruleList, "navigationPolicy": confinement.navigationPolicy,
                "refusesNewWindows": confinement.refusesNewWindows, "featuresOff": confinement.featuresOff,
            ],
            "switchesReadBack": switches ?? [:],
            "opened": opener.opened,
            "cases": records,
        ]
        do {
            try writeReport(report, to: out)
        } catch {
            FileHandle.standardError.write(Data("the report could not be written: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}

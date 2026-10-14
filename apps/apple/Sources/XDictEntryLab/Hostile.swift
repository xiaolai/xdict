import AppKit
import Foundation
import WebKit
import XDictEntryView

/// One case of the hostile battery (`Tools/hostile/battery.py` writes them into `cases.json`): the entry of that key,
/// how long to watch it, and whether it must run alone (a WebRTC host candidate's mDNS line names no page, only a time).
struct HostileCase: Decodable {
    let id: String
    let wait: Int
    let exclusive: Bool
    let tcp: Int
    let udp: Int
    let names: [String]

    /// Whether `html` still holds one of this case's own targets: the core's rewriter did not see it, so the view's
    /// layers are what stand between it and the network.
    func isLive(in html: String) -> Bool {
        html.contains("127.0.0.1:\(tcp)") || html.contains("127.0.0.1:\(udp)") || names.contains { html.contains($0) }
    }
}

struct HostileCases: Decodable {
    let cases: [HostileCase]
}

/// **The hostile battery through the production entry view** (or one with the named layers off): every case its own
/// window, its own `EntryViewController` and web view, fed by the core from the battery's dictionary. What WebKit asked
/// the view and what the view did is recorded per case; what left the machine is the observers' to say
/// (`Tools/hostile/observe.py`, mDNSResponder's log), and `Tools/hostile/analyze.py` joins the two.
///
/// A case's page reports what it saw into its own document (`data-lab` on the root element: the battery's `R()`), and
/// the lab reads that from a content world of its own; nothing is added to the view's configuration, so the production
/// configuration is exactly what is measured.
@MainActor
final class HostileRun {
    static let labWorld = WKContentWorld.world(name: "xdict-lab")

    private let options: LabOptions
    private let content: CoreContent
    private var queue: [HostileCase]
    private var running = 0
    private var exclusiveRunning = false
    private let opener = RecordingOpener()
    private var records: [String: [String: Any]] = [:]
    private var pages: [String: [[String]]] = [:]
    private var controllers: [String: EntryViewController] = [:]
    private var windows: [String: [NSWindow]] = [:]
    private var switches: [String: Bool]?
    private var finished: [String: Bool] = [:]

    init(options: LabOptions, content: CoreContent, cases: [HostileCase]) {
        self.options = options
        self.content = content
        self.queue = options.only.isEmpty ? cases : cases.filter { options.only.contains($0.id) }
    }

    func start() {
        pump()
    }

    private func pump() {
        while let next = queue.first, !exclusiveRunning, running < options.concurrency {
            if next.exclusive, running > 0 { break }
            queue.removeFirst()
            running += 1
            if next.exclusive { exclusiveRunning = true }
            launch(next, slot: running)
        }
        if running == 0, queue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { self.finish() } }
        }
    }

    private func environment(for id: String) -> EntryEnvironment {
        let directory = FileManager.default.temporaryDirectory.appending(path: "xdict-lab-rules")
        return EntryEnvironment(
            preferences: EntryPreferences(defaults: UserDefaults(suiteName: "ai.xdict.lab.hostile") ?? .standard),
            opener: opener, confinement: options.confinement, ruleListDirectory: directory,
            events: { [weak self] event in self?.note(id, event) },
            newWindow: { [weak self] configuration, action in self?.popup(id, configuration, action) })
    }

    private func launch(_ test: HostileCase, slot: Int) {
        let controller = EntryViewController(environment: environment(for: test.id))
        controllers[test.id] = controller
        records[test.id] = ["start": Date().timeIntervalSince1970, "events": [[String: Any]]()]
        let frame = NSRect(x: 40 + (slot % 4) * 330, y: 140, width: 320, height: 260)
        windows[test.id] = [labWindow(test.id, frame: frame, view: controller.view)]
        Task { @MainActor in
            let rendered = try? await content.entry(EntryReference(key: test.id))
            records[test.id]?["entryHoldsLiveTarget"] = rendered.map { test.isLive(in: String(decoding: $0.html, as: UTF8.self)) }
                ?? NSNull()
            if test.id.hasSuffix("~resource"), case .found(_, let bytes)? = try? await content.resource("\(test.id)/doc.html") {
                records[test.id]?["resourceHoldsLiveTarget"] = test.isLive(in: String(decoding: bytes, as: UTF8.self))
            }
            let shown = await controller.show(EntryReference(key: test.id), from: content)
            records[test.id]?["shown"] = shown
            if switches == nil { switches = controller.switchesReadBack }
        }
        poll(test.id, until: Date().addingTimeInterval(Double(test.wait) / 1000))
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(test.wait)) {
            MainActor.assumeIsolated { self.end(test) }
        }
    }

    /// The page's own reports, read every 100 ms while the case runs: a page that navigates away takes its reports
    /// with it, so they are read while they are there.
    private func poll(_ id: String, until deadline: Date) {
        guard Date() < deadline, let webView = controllers[id]?.webView else {
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { self.poll(id, until: deadline) } }
            }
            return
        }
        Task { @MainActor in
            await self.read(id, from: webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { self.poll(id, until: deadline) } }
        }
    }

    private func read(_ id: String, from webView: WKWebView) async {
        let script = "return document.documentElement ? document.documentElement.getAttribute('data-lab') : null"
        guard let value = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil,
                                                                  contentWorld: Self.labWorld) as? String,
              let data = value.data(using: .utf8),
              let reports = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return }
        var seen = pages[id] ?? []
        for report in reports {
            let pair = report.map { "\($0)" }
            if !seen.contains(pair) { seen.append(pair) }
        }
        pages[id] = seen
    }

    private func note(_ id: String, _ event: EntryEvent) {
        if case .documentFinished = event { finished[id] = true }
        var record = records[id] ?? [:]
        record["events", default: [[String: Any]]()] = (record["events"] as? [[String: Any]] ?? []) + [Report.describe(event)]
        records[id] = record
    }

    private func popup(_ id: String, _ configuration: WKWebViewConfiguration, _ action: WKNavigationAction) -> WKWebView? {
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        windows[id, default: []].append(labWindow("\(id) popup", frame: NSRect(x: 60, y: 460, width: 300, height: 200),
                                                  view: child))
        return child
    }

    private func end(_ test: HostileCase) {
        let controller = controllers[test.id]
        Task { @MainActor in
            if let webView = controller?.webView { await read(test.id, from: webView) }
            var record = records[test.id] ?? [:]
            record["end"] = Date().timeIntervalSince1970
            record["page"] = pages[test.id] ?? []
            record["loaded"] = (pages[test.id] ?? []).contains { $0.first == "loaded" }
            record["documentFinished"] = finished[test.id] ?? false
            record["finalURL"] = controller?.webView?.url?.absoluteString ?? ""
            record["refusal"] = controller?.refusal.map { String(describing: $0) } ?? NSNull()
            if let webView = controller?.webView {
                // Diagnostic SPI, the lab's alone: which WebKit processes served the case, so the analysis can name a
                // line in mDNSResponder's log that carries no delegator.
                record["networkPid"] = Self.pid(webView, "_networkProcessIdentifier")
                record["webPid"] = Self.pid(webView, "_webProcessIdentifier")
            }
            records[test.id] = record
            for window in windows[test.id] ?? [] {
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
            }
            controller?.closeEntry()
            for window in windows[test.id] ?? [] {
                window.contentView = nil
                window.close()
            }
            windows[test.id] = nil
            controllers[test.id] = nil
            running -= 1
            if test.exclusive { exclusiveRunning = false }
            pump()
        }
    }

    static func pid(_ object: NSObject, _ name: String) -> Any {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return NSNull() }
        typealias Getter = @convention(c) (NSObject, Selector) -> Int32
        return Int(unsafeBitCast(method, to: Getter.self)(object, selector))
    }

    private func finish() {
        let confinement = options.confinement
        let report: [String: Any] = [
            "mode": "hostile",
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "webkit": Report.webKitVersion,
            "disabled": options.disabled.sorted(),
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
            try Report.write(report, to: options.out ?? URL(fileURLWithPath: "/dev/null"))
        } catch {
            LabMain.die("could not write the report: \(error)")
        }
        exit(0)
    }
}

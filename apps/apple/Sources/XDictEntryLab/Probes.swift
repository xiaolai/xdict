import Foundation
import WebKit
import XDictEntryView
import XDictTokens

/// The events of one controller, kept in order with their time.
@MainActor
final class EventLog {
    private(set) var events: [(time: Double, event: EntryEvent)] = []

    func note(_ event: EntryEvent) { events.append((Date().timeIntervalSince1970, event)) }

    var described: [[String: Any]] { events.map { Report.describe($0.event).merging(["t": $0.time]) { _, new in new } } }

    var finishedCount: Int { events.filter { if case .documentFinished = $0.event { true } else { false } }.count }

    /// Requests answered or refused, and navigations decided: what "zero loads" counts.
    var loads: Int {
        events.filter {
            switch $0.event {
            case .served, .refusedRequest, .navigation, .documentFinished: true
            default: false
            }
        }.count
    }

    func served(since: Double = 0) -> [(handle: String, url: String, status: Int)] {
        events.compactMap {
            guard $0.time >= since, case .served(let handle, let url, let status, _, _) = $0.event else { return nil }
            return (handle, url, status)
        }
    }

    /// Waits until `count` documents have finished, or `seconds` pass.
    func waitForFinished(_ count: Int, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while finishedCount < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return finishedCount >= count
    }
}

/// Runs `body` in the lab's own content world of `webView` and returns its value.
@MainActor
func labEvaluate(_ webView: WKWebView?, _ body: String) async -> Any? {
    guard let webView else { return nil }
    return try? await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: HostileRun.labWorld)
}

/// **Fail closed, shown** (ADR-0009 refutation, item 5): the production entry view given switches with one deliberate
/// fault — no feature list, no feature, no setter, no getter, or a setter that changes nothing — must refuse with that
/// fault's own sentence and make no web view, so nothing loads.
@MainActor
enum FaultRun {
    static func run(_ fault: String, options: LabOptions, content: CoreContent) async throws -> [String: Any] {
        let log = EventLog()
        let environment = EntryEnvironment(
            preferences: EntryPreferences(defaults: UserDefaults(suiteName: "ai.xdict.lab.fault") ?? .standard),
            opener: RecordingOpener(), ruleListDirectory: FileManager.default.temporaryDirectory.appending(path: "xdict-lab-rules"),
            switches: { FaultySwitches(real: PreferencesSwitches($0), fault: fault) },
            events: { log.note($0) })
        let controller = EntryViewController(environment: environment)
        let window = labWindow("fault \(fault)", frame: Tokens.InstrumentFrame.probe, view: controller.view)
        let shown = await controller.show(EntryReference(key: "ok-xdict"), from: content)
        try await Task.sleep(for: .milliseconds(1500))
        let sentence = controller.refusal.map { String(localized: EntrySentences.refusal($0)) } ?? ""
        let report: [String: Any] = [
            "mode": "fault-switch", "fault": fault, "shown": shown,
            "refusal": controller.refusal.map { String(describing: $0) } ?? NSNull(),
            "sentence": sentence, "webViewMade": controller.webView != nil, "loads": log.loads,
            "events": log.described, "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        window.close()
        return report
    }
}

/// **One web view per dictionary, shown** (ADR-0009 refutation, item 13): A and B write the same resource paths with
/// different markers. A's marker request is held; the view switches to B; A's request is released. B must show B's
/// marker, and nothing answered from A may reach any view after the switch.
@MainActor
enum BindingRun {
    static let markerScript = """
        var m = document.getElementById('m');
        return m ? getComputedStyle(m).getPropertyValue('--marker').trim() : null
        """

    static func run(options: LabOptions, core: LabCore) async throws -> [String: Any] {
        guard options.twins.count == 2 else { throw LabFailure(description: "--binding needs two folders") }
        let a = HeldContent(try core.open(options.twins[0]), holding: "marker")
        let b = HeldContent(try core.open(options.twins[1]), holding: nil)
        let freeA = HeldContent(a.inner, holding: nil)
        let log = EventLog()
        let environment = EntryEnvironment(
            preferences: EntryPreferences(defaults: UserDefaults(suiteName: "ai.xdict.lab.binding") ?? .standard),
            opener: RecordingOpener(), ruleListDirectory: FileManager.default.temporaryDirectory.appending(path: "xdict-lab-rules"),
            events: { log.note($0) })
        let controller = EntryViewController(environment: environment)
        let window = labWindow("binding", frame: Tokens.InstrumentFrame.probe, view: controller.view)
        defer { window.close() }
        var steps: [String: Any] = [:]
        let word = EntryReference(key: "word")

        // B first, nothing held: B's marker is read as B's.
        await controller.show(word, from: b)
        _ = await log.waitForFinished(1, seconds: 10)
        try await Task.sleep(for: .milliseconds(400))
        steps["controlB"] = await labEvaluate(controller.webView, markerScript) ?? NSNull()

        // A, its marker held (so its document cannot finish); then B in its place; then A's answer let go.
        await controller.show(word, from: a)
        let deadline = Date().addingTimeInterval(10)
        while a.holding == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        steps["aHeld"] = a.holding
        let handleA = a.binding.handle, handleB = b.binding.handle
        steps["sameHandle"] = handleA == handleB
        await controller.show(word, from: b)
        _ = await log.waitForFinished(2, seconds: 10)
        try await Task.sleep(for: .milliseconds(400))
        let switched = Date().timeIntervalSince1970
        steps["bBeforeRelease"] = await labEvaluate(controller.webView, markerScript) ?? NSNull()
        a.release()
        try await Task.sleep(for: .milliseconds(1500))
        steps["bAfterRelease"] = await labEvaluate(controller.webView, markerScript) ?? NSNull()
        // Before A is shown again: anything served from A's package since the switch would be the confusion.
        steps["servedFromAAfterSwitch"] = log.served(since: switched).filter { $0.handle == handleA }
            .map { "\($0.status) \($0.url)" }

        // A again, nothing held: A's marker is read as A's, so the two are told apart.
        await controller.show(word, from: freeA)
        _ = await log.waitForFinished(3, seconds: 10)
        try await Task.sleep(for: .milliseconds(400))
        steps["controlA"] = await labEvaluate(controller.webView, markerScript) ?? NSNull()
        steps["aAnswered"] = a.log
        steps["bAnswered"] = b.log
        return ["mode": "binding", "steps": steps, "events": log.described,
                "pid": Int(ProcessInfo.processInfo.processIdentifier)]
    }
}

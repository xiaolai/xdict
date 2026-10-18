import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit
import XDictEntryView
import XDictTokens

/// **Reader-driven egress** (ADR-0009 refutation, item 8): the battery's `reader` entry in a production entry view,
/// and a drop target beside it, waiting for a person's hands — here a helper posting real pointer events
/// (`Tools/hostile/pointer.swift`). The stage asks through a directory of command files and reads the answers back:
///
///   <commands>/<n>.json  {"op": "targets" | "prompt" | "state" | "focus" | "front" | "deselect" | "scroll" | "quit"}
///   <commands>/<n>.out.json  the answer
///
/// `targets` gives each element's centre in global display coordinates (origin top left, as `CGEvent` takes them);
/// `prompt` the consent prompt's buttons, when one is up; `state` everything recorded so far; `focus` whether the lab
/// is active and its reader window key (`FocusLog`); `front` brings the lab forward. Nothing here clicks.
@MainActor
final class ReaderRun {
    private let options: LabOptions
    private let content: CoreContent
    private let log = EventLog()
    private let opener = RecordingOpener()
    private var controller: EntryViewController?
    private var window: NSWindow?
    private let drop = DropTarget()
    private var dropWindow: NSWindow?
    private var handled: Set<String> = []
    private let focus = FocusLog()

    init(options: LabOptions, content: CoreContent) {
        self.options = options
        self.content = content
    }

    func start() async throws {
        guard let commands = options.commands else { throw LabFailure(description: "--reader needs --commands") }
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        let environment = EntryEnvironment(
            preferences: EntryPreferences(defaults: UserDefaults(suiteName: "ai.xdict.lab.reader") ?? .standard),
            opener: opener, ruleListDirectory: FileManager.default.temporaryDirectory.appending(path: "xdict-lab-rules"),
            events: { [weak self] in self?.log.note($0) })
        let controller = EntryViewController(environment: environment)
        self.controller = controller
        focus.start()
        NSApp.activate()
        window = labWindow("reader", frame: Tokens.InstrumentFrame.reader, view: controller.view)
        window?.makeKeyAndOrderFront(nil)
        dropWindow = labWindow("drop here", frame: Tokens.InstrumentFrame.dropTarget, view: drop)
        await controller.show(EntryReference(key: "reader"), from: content)
        _ = await log.waitForFinished(1, seconds: 10)
        try await Task.sleep(for: .milliseconds(500))
        try Report.write(await targets(), to: commands.appending(path: "ready.json"))
        poll(commands)
    }

    private func poll(_ commands: URL) {
        Task { @MainActor in
            while true {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: commands.path)) ?? []
                for name in files.sorted() where name.hasSuffix(".json") && !name.hasSuffix(".out.json")
                    && name != "ready.json" && !handled.contains(name) {
                    handled.insert(name)
                    let url = commands.appending(path: name)
                    guard let data = try? Data(contentsOf: url),
                          let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let op = command["op"] as? String else { continue }
                    let answer = await perform(op, command)
                    let out = commands.appending(path: name.replacingOccurrences(of: ".json", with: ".out.json"))
                    try? Report.write(answer, to: out)
                    if op == "quit" {
                        try? Report.write(await state(), to: options.out ?? out)
                        exit(0)
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func perform(_ op: String, _ command: [String: Any]) async -> [String: Any] {
        switch op {
        case "targets": return await targets()
        case "prompt": return prompt()
        case "state", "quit": return await state()
        case "focus": return FocusLog.focus(of: window)
        case "front":
            // What a hand does before it clicks, done by the lab: its windows ordered above every other application's
            // and the lab asked to be active. The system may decline the asking while another application is active;
            // `reader.py` waits for the outcome, asks LaunchServices if it must, and names what stood in the way.
            dropWindow?.orderFrontRegardless()
            window?.orderFrontRegardless()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return FocusLog.focus(of: window)
        case "deselect":
            // A selection left by an earlier click would be what a drag carries, not the element under the pointer.
            _ = await labEvaluate(controller?.webView, "window.getSelection().removeAllRanges(); return true")
            return await state()
        case "scroll":
            _ = await labEvaluate(controller?.webView, "window.scrollTo(0, 0); return true")
            return await targets()
        default: return ["error": "no op \(op)"]
        }
    }

    /// Each element with an id in the entry, by its centre in global display coordinates (top-left origin).
    private func targets() async -> [String: Any] {
        guard let webView = controller?.webView, let window = webView.window,
              let rects = await labEvaluate(webView, """
                  var out = {};
                  document.querySelectorAll('[id]').forEach(function (e) {
                    var r = e.getBoundingClientRect();
                    if (r.width > 0 && r.height > 0) out[e.id] = [r.left, r.top, r.width, r.height];
                  });
                  return out
                  """) as? [String: [Double]] else { return ["error": "no web view or no targets"] }
        var points: [String: [Double]] = [:]
        for (id, r) in rects where r.count == 4 {
            // CSS pixels at the view's zoom, from the view's top left (WKWebView is flipped), to the window, the screen,
            // and Quartz's global space, whose origin is the main display's top left.
            let zoom = webView.pageZoom
            let local = NSPoint(x: (r[0] + r[2] / 2) * zoom, y: (r[1] + r[3] / 2) * zoom)
            let inWindow = webView.convert(local, to: nil)
            points[id] = Self.global(window.convertPoint(toScreen: inWindow))
        }
        let dropCentre = drop.window.map { Self.global($0.convertPoint(toScreen: drop.convert(NSPoint(x: 150, y: 150), to: nil))) }
        return ["targets": points, "drop": dropCentre ?? [], "zoom": webView.pageZoom]
    }

    /// The consent prompt's two buttons, when it is up.
    private func prompt() -> [String: Any] {
        guard let alert = controller?.presentedPrompt else { return ["presented": false] }
        var buttons: [String: [Double]] = [:]
        for (index, button) in alert.buttons.enumerated() {
            guard let window = button.window else { continue }
            let centre = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            buttons[index == 0 ? "open" : "cancel"] = Self.global(window.convertPoint(toScreen: centre))
        }
        return ["presented": true, "message": alert.messageText, "buttons": buttons]
    }

    private func state() async -> [String: Any] {
        [
            "mode": "reader", "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "events": log.described, "opened": opener.opened, "drops": drop.received,
            "promptPresented": controller?.presentedPrompt != nil,
            "focus": FocusLog.focus(of: window), "timeline": focus.timeline,
            "url": controller?.webView?.url?.absoluteString ?? "",
            "networkPid": controller?.webView.map { HostileRun.pid($0, "_networkProcessIdentifier") } ?? NSNull(),
            "webPid": controller?.webView.map { HostileRun.pid($0, "_webProcessIdentifier") } ?? NSNull(),
        ]
    }

    static func global(_ screen: NSPoint) -> [Double] {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return [Double(screen.x), Double(height - screen.y)]
    }
}

/// A view that takes whatever is dropped on it — URLs, files, file promises — and says what it got. A file promise is
/// received into a scratch folder, so whatever WebKit would do to keep it (fetch it, write it) is done.
@MainActor
final class DropTarget: NSView {
    private(set) var received: [[String: Any]] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.URL, .fileURL, .string, .tiff, .png] + NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        })
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.2).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        var item: [String: Any] = ["t": Date().timeIntervalSince1970,
                                   "types": (board.types ?? []).map(\.rawValue),
                                   "string": board.string(forType: .string) ?? "",
                                   "url": board.string(forType: .URL) ?? ""]
        let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        item["promises"] = promises.count
        let scratch = FileManager.default.temporaryDirectory.appending(path: "xdict-lab-drops")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let index = received.count
        received.append(item)
        for promise in promises {
            promise.receivePromisedFiles(atDestination: scratch, operationQueue: .main) { url, error in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
                Task { @MainActor in
                    self.received[index]["promised", default: [String]()] =
                        (self.received[index]["promised"] as? [String] ?? []) + ["\(url.lastPathComponent) \(size ?? -1) \(error.map { "\($0)" } ?? "")"]
                }
            }
        }
        return true
    }
}

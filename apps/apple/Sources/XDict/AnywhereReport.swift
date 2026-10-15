import AppKit
import ApplicationServices
import XDictAnywhere
import XDictClient
import XDictContract
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictUI

/// `XDict --anywhere <work> --fixtures <lookup>`: a development instrument for the E2E `anywhere` sub-stages
/// (plan-macos-v1 WI-8; run on the E2E Mac only). **The real app** — its shortcut, its Service, its panel, its menu-bar
/// item, its main window — over a library of its own in `<work>/store` holding the lookup fixtures' Alpha and Beta. Other
/// apps, keys, clicks and menus are the driver's (`Tools/anywhere/drive.py` with `hands`); this only says what XDict did.
///
/// It writes `<work>/events.jsonl`, one line per thing the panel did (`pressed`, `service`, `shown`, `closed`,
/// `expanded`), each with its wall-clock time; and answers the driver through `<work>/commands`: `NNN.json` asks
/// (`state`, `rebind`, `quit`), `NNN.out.json` answers. It writes `<work>/ready.json` once the library answers.
enum AnywhereReport {
    static let flag = "--anywhere"

    static func setup(_ arguments: [String]) -> AppSetup? {
        guard let work = Instrument.value(after: flag, in: arguments) else { return nil }
        return AppSetup(libraryDirectory: URL(fileURLWithPath: work).appending(path: "store"), service: ServiceClient(),
                        entryEvents: nil, speechVolume: 0, speechSuite: InstrumentWindow.speechSuite)
    }

    @MainActor
    static func prepare(_ arguments: [String]) {
        guard let work = Instrument.value(after: flag, in: arguments).map(URL.init(fileURLWithPath:)),
              let fixtures = Instrument.value(after: "--fixtures", in: arguments).map(URL.init(fileURLWithPath:)) else {
            FileHandle.standardError.write(Data("usage: \(flag) <work> --fixtures <lookup>\n".utf8))
            exit(2)
        }
        let run = AnywhereRun(work: work, fixtures: fixtures)
        AnywhereRun.shared = run
        LookupAnywhere.shared.observe = { name, detail in run.event(name, detail) }
        Task { await run.begin() }
    }
}

@MainActor
final class AnywhereRun {
    static var shared: AnywhereRun?
    let work: URL
    let fixtures: URL
    private var answered: Set<String> = []
    private var commands: URL { work.appending(path: "commands") }

    init(work: URL, fixtures: URL) {
        self.work = work
        self.fixtures = fixtures
    }

    func event(_ name: String, _ detail: [String: Any]) {
        var line = detail
        line["event"] = name
        line["at"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        let url = work.appending(path: "events.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    func begin() async {
        try? FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        // Waits for the app's own launch (the delegate starts the library and the panel), then adds the fixtures once.
        while LookupAnywhere.shared.panelState == nil { try? await Task.sleep(for: .milliseconds(50)) }
        let library = XDictApp.library
        let copy = work.appending(path: "dictionaries")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.copyItem(at: fixtures, to: copy)
            for name in ["alpha", "beta"] { _ = library.add([copy.appending(path: "\(name)/\(name).mdx")]) }
        }
        let settled = await library.settled(within: .seconds(120))
        LookupAnywhere.shared.panelState?.model.sourcesDidChange()
        try? writeReport(["pid": Int(getpid()), "settled": settled, "trusted": AXIsProcessTrusted(),
                          "dictionaries": library.searchSources.map(\.name)],
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
                Task { try? writeReport(await self.state(), to: out) }
            case "rebind":
                let chosen = Shortcut(keyCode: UInt32(asked["keyCode"] as? Int ?? -1),
                                      modifiers: UInt32(asked["modifiers"] as? Int ?? 0))
                let problem = LookupAnywhere.shared.registrar.choose(chosen)
                let said: Any = problem.map { String(describing: $0) } ?? NSNull()
                let sentence: Any = problem.map { String(localized: AnywhereSentences.problem($0)) } ?? NSNull()
                try? writeReport(["problem": said, "sentence": sentence], to: out)
            case "quit":
                try? writeReport(["quitting": true], to: out)
                exit(0)
            default:
                try? writeReport(["error": "no op \(op)"], to: out)
            }
        }
    }

    private func state() async -> [String: Any] {
        let anywhere = LookupAnywhere.shared
        let registrar = anywhere.registrar
        var out: [String: Any] = [
            "pid": Int(getpid()), "active": NSApp.isActive, "trusted": AXIsProcessTrusted(),
            "screenHeight": Double(NSScreen.screens.first?.frame.height ?? 0),
            "keyWindow": NSApp.keyWindow?.identifier?.rawValue ?? NSNull(),
            "shortcut": ["label": registrar.current.label(), "keyCode": Int(registrar.current.keyCode),
                         "modifiers": Int(registrar.current.modifiers), "registered": registrar.isRegistered,
                         "problem": registrar.problem.map { String(describing: $0) } ?? NSNull()],
            "panel": ["shown": anywhere.isShown, "frame": anywhere.panelFrame.map(LookupAnywhere.describe) ?? NSNull(),
                      "notice": String(describing: anywhere.notice)],
        ]
        if let state = anywhere.panelState {
            out["panelModel"] = await Self.describe(state)
        }
        if let main = MainWindows.front {
            out["main"] = await Self.describe(main)
        }
        return out
    }

    static func describe(_ state: SearchWindowState) async -> [String: Any] {
        let model = state.model
        var out: [String: Any] = ["query": model.lookup?.query ?? NSNull(), "text": model.text,
                                  "scroll": await state.entry.scrollOffset() ?? NSNull(),
                                  "visible": state.entry.view.window?.isVisible == true,
                                  "isKey": state.entry.view.window?.isKeyWindow == true]
        if let shown = model.shown {
            out["dictionary"] = model.source(shown.result.dictionary)?.name ?? "?"
            out["key"] = shown.result.entry.key
            out["occurrence"] = Int(shown.result.entry.occurrence)
        }
        if let window = state.entry.view.window {
            out["entryFrame"] = LookupAnywhere.describe(window.convertToScreen(
                state.entry.view.convert(state.entry.view.bounds, to: nil)))
        }
        return out
    }
}

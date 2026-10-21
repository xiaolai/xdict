import Foundation
import Testing
import XDictTestSupport

/// **A driven run starts no hover** (plan-capture WI-3): a key an instrument holds must not open a lookup it did not ask
/// for. Every instrument that prepares the real app rather than exiting — `X.prepare(` in `main.swift` — must have its
/// `X.flag` in the line that sets `LookupAnywhere.launch`, and the app must start hover only with that launch
/// (`HoverControl.startAtLaunch`, whose guards `HoverControlTests` holds). Read off the code, since the app target cannot
/// run under a test; positive controls plant each mistake.
struct DrivenInstrumentTests {
    static let launchLine = "LookupAnywhere.launch ="

    @Test func everyDrivenInstrumentTurnsHoverOff() throws {
        let main = Manifest.package.appending(path: "Sources/XDict/main.swift")
        let text = try String(contentsOf: main, encoding: .utf8)
        // The premise: the three driven instruments of today are seen. A scan that finds none holds nothing.
        #expect(Self.prepared(text).count >= 3, "the scan read no driven instrument: \(Self.prepared(text))")
        #expect(Self.forgotten(text) == [])
    }

    /// **The app starts hover with the launch it was given, and only so**: one call, `startAtLaunch(Self.launch)`.
    @Test func theAppStartsHoverOnlyWithItsLaunch() throws {
        let app = Manifest.package.appending(path: "Sources/XDict/LookupAnywhere.swift")
        #expect(Self.startProblems(try String(contentsOf: app, encoding: .utf8)) == [])
    }

    /// **The controls**: an instrument prepared but missing from the line is named; one present is not.
    @Test func aDrivenInstrumentTheLineForgotIsNamed() {
        let planted = """
            if arguments.contains(AReport.flag) {
                AReport.prepare(arguments)
            }
            if arguments.contains(BReport.flag) {
                BReport.prepare(arguments)
            }
            LookupAnywhere.launch = HoverLaunch.of(arguments: arguments, instrumentFlags: [AReport.flag])
            """
        #expect(Self.forgotten(planted) == ["BReport"])
        #expect(Self.forgotten("AReport.prepare(arguments)\n") == ["AReport"], "a missing line hid the instrument")
    }

    @Test func aHoverStartThatIgnoresTheLaunchIsNamed() {
        #expect(Self.startProblems("hover.startAtLaunch(Self.launch)\n") == [])
        #expect(Self.startProblems("hover.startAtLaunch(.reader)\n") == ["a start without the launch: 1", "no start with the launch"])
        #expect(Self.startProblems("hover.startAtLaunch(Self.launch)\nhover.setEnabled(true)\n") == [],
                "the Settings toggle is the reader's own act, not a launch")
        #expect(Self.startProblems("// hover.startAtLaunch(Self.launch)\n") == ["no start with the launch"])
    }

    /// **The menu-bar pause group and Settings' switch show the reader's setting** (`HoverControl.isOn`), never whether
    /// the watcher runs: in a driven run it never does, and the menu said "Hover Is Off in Settings" with hover on, while
    /// the switch read off and a click on it turned hover on (UI tour, 2026-10-19).
    @Test func theMenuAndTheSwitchShowTheSettingNotTheWatcher() throws {
        for file in ["Sources/XDict/MenuBarItem.swift", "Sources/XDictUI/HoverSettings.swift"] {
            let text = try String(contentsOf: Manifest.package.appending(path: file), encoding: .utf8)
            #expect(Self.watcherReads(text) == [], "\(file)")
        }
    }

    @Test func aViewReadingTheWatcherIsNamed() {
        #expect(Self.watcherReads("Toggle(isOn: Binding(get: { hover.isOn }, set: { hover.setEnabled($0) }))\n") == [])
        #expect(Self.watcherReads("Toggle(isOn: Binding(get: { hover.isWatching }, set: { _ in }))\n") == ["isWatching"])
        #expect(Self.watcherReads("entries(hoverIsOn: hover.watcher.isWatching, pausedUntil: nil, now: now)\n")
                == ["isWatching"])
        #expect(Self.watcherReads("// hover.isWatching, said in a comment\n") == [])
    }

    static func watcherReads(_ text: String) -> [String] {
        let reads = SourceScan.codeOnly(text).components(separatedBy: "isWatching").count - 1
        return Array(repeating: "isWatching", count: reads)
    }

    static func prepared(_ text: String) -> [String] {
        SourceScan.codeOnly(text).matches(of: /\b([A-Z][A-Za-z0-9]*)\.prepare\(/).map { String($0.output.1) }
    }

    static func forgotten(_ text: String) -> [String] {
        let code = SourceScan.codeOnly(text)
        let line = code.split(separator: "\n").first { $0.contains(launchLine) } ?? ""
        return prepared(text).filter { !line.contains("\($0).flag") }
    }

    static func startProblems(_ text: String) -> [String] {
        let code = SourceScan.codeOnly(text)
        let starts = code.matches(of: /startAtLaunch\(/).count
        let withLaunch = code.matches(of: /startAtLaunch\(Self\.launch\)/).count
        var problems: [String] = []
        if starts > withLaunch { problems.append("a start without the launch: \(starts - withLaunch)") }
        if withLaunch == 0 { problems.append("no start with the launch") }
        return problems
    }
}

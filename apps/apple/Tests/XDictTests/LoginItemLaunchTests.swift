import Foundation
import Testing
import XDictTestSupport

/// **Only the reader's switch makes XDict a login item** (verifier, 2026-10-19; XiaolaiDict's Startup section): no launch
/// path, no scene and no Settings appearance registers or unregisters it. Read off the code, since the app cannot run
/// under a test: in the app and the view layer a registration — `.register()`, `.unregister()`, or `.set(` on a
/// `LaunchAtLogin` — may stand only in the Settings switch's `set:` closure, and in the setup instrument
/// (`SetupReport.swift`, an E2E stage run by its flag, which registers and unregisters to check `SMAppService` answers).
/// `LaunchAtLogin.swift` is the service itself. Positive controls plant each mistake.
struct LoginItemLaunchTests {
    static let folders = ["Sources/XDict", "Sources/XDictUI"]
    /// Where a registration may be written, by file, and why.
    static let allowed = ["SetupReport.swift": "the setup instrument, an E2E stage run only by its flag",
                          "LaunchAtLogin.swift": "the login item service and its model"]

    @Test func noLaunchPathRegistersTheLoginItem() throws {
        var files: [(name: String, text: String)] = []
        for folder in Self.folders {
            files += try SourceScan.files(under: Manifest.package.appending(path: folder))
                .map { ($0.file.lastPathComponent, $0.text) }
        }
        // The premise: the app's one login item and the Settings switch are read.
        #expect(files.contains { $0.text.contains("loginItem") } && files.contains { $0.name == "GeneralSettings.swift" },
                "the scan did not read the app's login item")
        #expect(Self.problems(files) == [])
    }

    /// The controls (M17): registering at launch, in a scene's task, through the service directly, and unregistering
    /// on Settings' appearance are each named; the switch's own `set:` and the instrument are not.
    @Test func eachRegistrationOutsideTheSwitchIsNamed() {
        let launch = """
            func applicationDidFinishLaunching(_ notification: Notification) {
                XDictApp.loginItem.set(true)
            }
            """
        let scene = ".task { MainAppLoginItem().register() }\n"
        let settings = """
            Toggle(isOn: Binding(get: { login.isOn }, set: { login.set($0) })) { Text("Open") }
            .onAppear { login.set(false) }
            """
        let service = "try SMAppService.mainApp.unregister()\n"
        #expect(Self.problems([("XDictApp.swift", launch)]) == ["XDictApp.swift:2"])
        #expect(Self.problems([("XDictApp.swift", scene)]) == ["XDictApp.swift:1"])
        #expect(Self.problems([("GeneralSettings.swift", settings)]) == ["GeneralSettings.swift:2"])
        #expect(Self.problems([("Other.swift", service)]) == ["Other.swift:1"])
        #expect(Self.problems([("SetupReport.swift", "login.set(true)\nlogin.set(false)\n")]) == [])
        #expect(Self.problems([("XDictApp.swift", "// XDictApp.loginItem.set(true)\n")]) == [], "a comment is not code")
    }

    /// Each line, outside the allowed files, that registers or unregisters, unless it is the switch's `set:` closure.
    static func problems(_ files: [(name: String, text: String)]) -> [String] {
        files.filter { allowed[$0.name] == nil }.flatMap { name, text in
            SourceScan.codeOnly(text).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .compactMap { index, line -> String? in
                    let registers = line.contains(/\.(?:un)?register\(\)/)
                        // Classes, not `\b`: under Unicode's word boundary `XDictApp.loginItem` is one word.
                        || line.contains(/(?:^|[^A-Za-z0-9_])(?:login|loginItem|LaunchAtLogin\([^)]*\))\.set\(/)
                    guard registers else { return nil }
                    let theSwitch = line.contains(/set:\s*\{\s*login\.set\(\$0\)\s*\}/)
                    return theSwitch ? nil : "\(name):\(index + 1)"
                }
        }
    }
}

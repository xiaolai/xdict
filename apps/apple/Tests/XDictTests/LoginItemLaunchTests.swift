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
            @Bindable private var login: LaunchAtLogin
            Toggle(isOn: Binding(get: { login.isOn }, set: { login.set($0) })) { Text("Open") }
            .onAppear { login.set(false) }
            """
        let service = "try SMAppService.mainApp.unregister()\n"
        #expect(Self.problems([("XDictApp.swift", launch)]) == ["XDictApp.swift:2"])
        // Made and registered on one line: one finding a line.
        #expect(Self.problems([("XDictApp.swift", scene)]) == ["XDictApp.swift:1"])
        #expect(Self.problems([("GeneralSettings.swift", settings)]) == ["GeneralSettings.swift:3"])
        #expect(Self.problems([("Other.swift", service)]) == ["Other.swift:1"])
        #expect(Self.problems([("SetupReport.swift", "login.set(true)\nlogin.set(false)\n")]) == [])
        #expect(Self.problems([("XDictApp.swift", "// XDictApp.loginItem.set(true)\n")]) == [], "a comment is not code")
    }

    /// **Independent of names** (verifier round 2, R17, R17b, R17c): the login item is made in exactly one place — the
    /// app's one static — and a registration on any value of its type is named whatever the value is called: a local
    /// made inside the static's initialiser, the same renamed, a local holding the static, a property of the type under
    /// another name. The app's own static line and the switch on a renamed property are not.
    @Test func aRegistrationIsNamedWhateverItsValueIsCalled() {
        for local in ["item", "made"] {
            let inside = """
                static let loginItem: LaunchAtLogin = {
                    let \(local) = LaunchAtLogin(service: MainAppLoginItem())
                    \(local).set(true)
                    return \(local)
                }()
                """
            #expect(Self.problems([("XDictApp.swift", inside)]) == ["XDictApp.swift:2", "XDictApp.swift:3"], "\(local)")
        }
        let held = "let held = XDictApp.loginItem\nheld.set(true)\n"
        #expect(Self.problems([("XDictApp.swift", held)]) == ["XDictApp.swift:2"])
        let theStatic = "@MainActor static let loginItem = LaunchAtLogin(service: MainAppLoginItem())\n"
        #expect(Self.problems([("XDictApp.swift", theStatic)]) == [])
        #expect(Self.problems([("Other.swift", theStatic)]) == ["Other.swift:1"], "the static is the app's alone")
        let renamed = """
            @Bindable private var startup: LaunchAtLogin
            Toggle(isOn: Binding(get: { startup.isOn }, set: { startup.set($0) })) { Text("Open") }
            .task { startup.set(true) }
            """
        #expect(Self.problems([("GeneralSettings.swift", renamed)]) == ["GeneralSettings.swift:3"])
        #expect(Self.problems([("Other.swift", renamed)]) == ["Other.swift:2", "Other.swift:3"],
                "the switch is Settings' alone")
        #expect(Self.problems([("Other.swift", "let service = MainAppLoginItem()\n")]) == ["Other.swift:1"])
        #expect(Self.problems([("Other.swift", "_ = SMAppService.mainApp.status\n")]) == ["Other.swift:1"])
    }

    /// The one place the app makes its login item: `XDictApp`'s static, on one line, exactly so.
    static var theStatic: Regex<Substring> {
        /^\s*(?:@MainActor\s+)?static\s+let\s+loginItem\s*=\s*LaunchAtLogin\(service:\s*MainAppLoginItem\(\)\)\s*$/
    }

    /// Each line, outside the allowed files, that makes the login item anywhere but the app's static, touches
    /// `SMAppService`, or registers or unregisters — `.register()`, `.unregister()`, or `.set(` on any value of the
    /// login item's type, whatever it is called — unless it is Settings' switch, `set: { <value>.set($0) }`.
    ///
    /// **The values of the type, by what they are bound to, never by name**: a name declared `: LaunchAtLogin`, a local
    /// bound to `LaunchAtLogin(…)` or to the static (`loginItem`), and a local bound to any of those, to a fixed point;
    /// the static itself, however it is reached. Classes, not `\b`: under Unicode's word boundary `XDictApp.loginItem`
    /// is one word.
    static func problems(_ files: [(name: String, text: String)]) -> [String] {
        files.filter { allowed[$0.name] == nil }.flatMap { name, text in
            let code = SourceScan.codeOnly(text)
            let values = valuesOfTheType(in: code)
            let names = values.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            let onAValue = try? Regex<Substring>("(?:^|[^A-Za-z0-9_.])(?:\(names))\\.set\\(")
            let switchOnAValue = try? Regex<Substring>("set:\\s*\\{\\s*(?:\(names))\\.set\\(\\$0\\)\\s*\\}")
            return code.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .compactMap { index, line -> String? in
                    let isTheStatic = name == "XDictApp.swift" && line.contains(theStatic)
                    // Made, or the system's service reached; a type named in a declaration is neither.
                    let makes = !isTheStatic
                        && line.contains(/(?:^|[^A-Za-z0-9_])(?:LaunchAtLogin\s*\(|MainAppLoginItem\s*\(|SMAppService(?![A-Za-z0-9_]))/)
                    var registers = line.contains(/\.(?:un)?register\(\)/)
                        || line.contains(/(?:^|[^A-Za-z0-9_])loginItem\.set\(/)
                    if let onAValue, !values.isEmpty, line.contains(onAValue) {
                        let theSwitch = name == "GeneralSettings.swift" && switchOnAValue.map { line.contains($0) } == true
                        registers = registers || !theSwitch
                    }
                    return makes || registers ? "\(name):\(index + 1)" : nil
                }
        }
    }

    /// The names that hold the login item's type in `code` (see `problems`).
    static func valuesOfTheType(in code: String) -> Set<String> {
        var values = Set(code.matches(of: /([A-Za-z_][A-Za-z0-9_]*)\s*:\s*LaunchAtLogin(?![A-Za-z0-9_])/).map { String($0.output.1) })
        let bindings = code.matches(of: /(?:^|[^A-Za-z0-9_])(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)[^=\n]*=([^\n]*)/)
            .map { (name: String($0.output.1), value: String($0.output.2)) }
        var grew = true
        while grew {
            grew = false
            for (bound, value) in bindings where !values.contains(bound) {
                let words = Set(value.matches(of: /[A-Za-z_][A-Za-z0-9_]*/).map { String($0.output) })
                if value.contains(/LaunchAtLogin\(|(?:^|[^A-Za-z0-9_])loginItem(?![A-Za-z0-9_])/) || !words.isDisjoint(with: values) {
                    values.insert(bound)
                    grew = true
                }
            }
        }
        return values
    }
}

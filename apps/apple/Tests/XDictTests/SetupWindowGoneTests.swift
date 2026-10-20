import Foundation
import Testing
import XDictTestSupport

/// **The setup window is gone** (ADR-0012, amended 2026-10-20; the owner asked for no separate window): no scene, no
/// window id, and every way in opens Settings ▸ Setup (`SettingsRouteTests.theSetupBoardIsAPaneOfSettings`). Read off
/// the code, since the app target runs no test; positive controls plant each mistake.
struct SetupWindowGoneTests {
    static func sources() throws -> [(name: String, text: String)] {
        let root = Manifest.package.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.map { ($0.path, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// The scan sees the sources at all: a scan of nothing would pass every check below.
    @Test func theScanReadsTheApp() throws {
        let all = try Self.sources()
        #expect(all.contains { $0.name.hasSuffix("XDict/XDictApp.swift") && $0.text.contains("Settings {") })
    }

    @Test func noSetupWindowIsLeft() throws {
        for file in try Self.sources() {
            #expect(!Self.declaresSetupWindow(file.text), "\(file.name) still declares the setup window")
            #expect(!file.text.contains("setupWindow"), "\(file.name) still names the setup window")
        }
    }

    /// Every way in goes through the route, not through a window id.
    @Test func everyWayInOpensThePane() throws {
        let app = try Self.sources().first { $0.name.hasSuffix("XDict/XDictApp.swift") }?.text ?? ""
        #expect(Self.openingRoutes(app) == 2, "the scan read \(Self.openingRoutes(app)) routed opens, wanted menu and first launch")
    }

    static func declaresSetupWindow(_ text: String) -> Bool {
        text.contains("Window(\"Set Up XDict\"")
    }

    /// `SettingsRoute.shared.showSetup()` sites: the app menu's action and the first launch.
    static func openingRoutes(_ text: String) -> Int {
        SourceScan.codeOnly(text).matches(of: /SettingsRoute\.shared\.showSetup\(\)/).count
    }

    /// Positive controls: the patterns see the mistakes they exist for.
    @Test func thePatternsSeeTheMistakes() {
        #expect(Self.declaresSetupWindow(#"Window("Set Up XDict", id: Self.setupWindow) {"#))
        #expect(!Self.declaresSetupWindow(#"Settings {"#))
        #expect(Self.openingRoutes("SettingsRoute.shared.showSetup()\n") == 1)
    }
}

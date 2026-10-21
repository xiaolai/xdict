import Foundation
import Testing
import XDictTestSupport

/// **The menu-bar item is the app's own, and the menu-bar switch reaches the app** (Settings ▸ General, `MenuBarResidence`;
/// plan-history-and-learning §4). Read off the code, since the app target cannot run under a test: the delegate answers
/// `applicationShouldTerminateAfterLastWindowClosed` from the reader's choice; an `NSStatusItem` is installed with a click
/// that routes a primary press to the history and a secondary one to the menu (XiaolaiDict's measured design); and no
/// `MenuBarExtra` is used at all — measured, SwiftUI drives its button privately and a right click cannot reach it, and an
/// `isInserted:` binding rebuilt the main menu forever on macOS 27 and hung the launch (`ui-fix`, 2026-10-17).
struct MenuBarWiringTests {
    @Test func theAppAnswersFromTheReadersChoiceAndOwnsItsStatusItem() throws {
        let app = Manifest.package.appending(path: "Sources/XDict")
        let files = try SourceScan.files(under: app).map { (name: $0.file.lastPathComponent, text: $0.text) }
        // The premise: the app's item is read. A scan that finds no status item holds nothing.
        #expect(files.contains { SourceScan.codeOnly($0.text).contains("NSStatusBar.system.statusItem") },
                "no status item was read")
        #expect(Self.problems(files) == [])
    }

    @Test func eachMistakeIsNamed() {
        let wired = """
            func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
                MenuBarResidence(defaults: .standard).terminatesAfterLastWindowClosed
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if StatusItemClick.isSecondary(NSApp.currentEvent) { showMenu() }
            """
        #expect(Self.problems([("App.swift", wired)]) == [])
        #expect(Self.problems([("App.swift", "let item = NSStatusBar.system.statusItem(withLength: 0)\n")])
                == ["no delegate answer from MenuBarResidence",
                    "no click routing: a right click cannot reach the menu"])
        let inserted = wired + "\nMenuBarExtra(isInserted: $shown) { menu } label: { label }\n"
        #expect(Self.problems([("App.swift", inserted)]) == ["App.swift:6: MenuBarExtra (it cannot route a right click)"])
        let plain = wired + "\nMenuBarExtra { menu } label: { label }\n"
        #expect(Self.problems([("App.swift", plain)]) == ["App.swift:6: MenuBarExtra (it cannot route a right click)"])
        let noRouting = wired.replacingOccurrences(of: "if StatusItemClick.isSecondary(NSApp.currentEvent) { showMenu() }",
                                                   with: "")
        #expect(Self.problems([("App.swift", noRouting)]) == ["no click routing: a right click cannot reach the menu"])
        #expect(Self.problems([("App.swift", "// MenuBarExtra { menu } label: { label }\n" + wired)]) == [],
                "a comment is not code")
    }

    static func problems(_ files: [(name: String, text: String)]) -> [String] {
        var found: [String] = []
        var answered = false
        var routes = false
        for (name, text) in files {
            let code = SourceScan.codeOnly(text)
            if code.contains(/applicationShouldTerminateAfterLastWindowClosed[^{]*\{\s*MenuBarResidence\([^)]*\)\.terminatesAfterLastWindowClosed\s*\}/) {
                answered = true
            }
            if code.contains("StatusItemClick.isSecondary") { routes = true }
            for (index, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("MenuBarExtra") {
                found.append("\(name):\(index + 1): MenuBarExtra (it cannot route a right click)")
            }
        }
        if !answered { found.insert("no delegate answer from MenuBarResidence", at: 0) }
        if !routes { found.append("no click routing: a right click cannot reach the menu") }
        return found
    }
}

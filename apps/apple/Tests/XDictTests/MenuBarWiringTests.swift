import Foundation
import Testing
import XDictTestSupport

/// **The menu-bar switch reaches the app, and the menu-bar item is never inserted conditionally** (Settings ▸ General,
/// `MenuBarResidence`). Read off the code, since the app target cannot run under a test: the delegate answers
/// `applicationShouldTerminateAfterLastWindowClosed` from the reader's choice, and no source of the app passes
/// `isInserted:` to a `MenuBarExtra`, which rebuilt the main menu forever on macOS 27 and hung the launch (`ui-fix`,
/// 2026-10-17). Positive controls plant each mistake.
struct MenuBarWiringTests {
    @Test func theAppAnswersFromTheReadersChoiceAndInsertsTheItemAlways() throws {
        let app = Manifest.package.appending(path: "Sources/XDict")
        let files = try SourceScan.files(under: app).map { (name: $0.file.lastPathComponent, text: $0.text) }
        // The premise: the app's scene is read. A scan that reads no MenuBarExtra holds nothing.
        #expect(files.contains { SourceScan.codeOnly($0.text).contains("MenuBarExtra") }, "no MenuBarExtra was read")
        #expect(Self.problems(files) == [])
    }

    @Test func eachMistakeIsNamed() {
        let wired = """
            func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
                MenuBarResidence(defaults: .standard).terminatesAfterLastWindowClosed
            }
            MenuBarExtra { menu } label: { label }
            """
        #expect(Self.problems([("App.swift", wired)]) == [])
        #expect(Self.problems([("App.swift", "MenuBarExtra { menu } label: { label }\n")])
                == ["no delegate answer from MenuBarResidence"])
        let inserted = wired + "\nMenuBarExtra(isInserted: $shown) { menu } label: { label }\n"
        #expect(Self.problems([("App.swift", inserted)]) == ["App.swift:5: MenuBarExtra(isInserted:)"])
        let fixed = """
            func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
            """
        #expect(Self.problems([("App.swift", fixed)]) == ["no delegate answer from MenuBarResidence"])
        #expect(Self.problems([("App.swift", "// MenuBarExtra(isInserted: x)\n" + wired)]) == [],
                "a comment is not code")
    }

    static func problems(_ files: [(name: String, text: String)]) -> [String] {
        var found: [String] = []
        var answered = false
        for (name, text) in files {
            let code = SourceScan.codeOnly(text)
            if code.contains(/applicationShouldTerminateAfterLastWindowClosed[^{]*\{\s*MenuBarResidence\([^)]*\)\.terminatesAfterLastWindowClosed\s*\}/) {
                answered = true
            }
            for (index, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(/isInserted\s*:/) {
                found.append("\(name):\(index + 1): MenuBarExtra(isInserted:)")
            }
        }
        if !answered { found.insert("no delegate answer from MenuBarResidence", at: 0) }
        return found
    }
}

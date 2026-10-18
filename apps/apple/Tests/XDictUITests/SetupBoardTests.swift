import Foundation
import Testing
import XDictUI

/// **The setup board reads live state, every time** (plan-macos-v1 WI-9; adapted from XiaolaiDict's `SetupBoardTests`):
/// each row is a fact about now, so a permission granted in System Settings completes its row with no relaunch and no
/// remembered progress.
struct SetupBoardTests {
    @Test func aFreshAccountNeedsDictionariesAndAccessibility() {
        let board = SetupBoard(dictionaries: 0, trusted: false, shortcutWorks: true)
        #expect(board.state(of: .dictionaries) == .needed)
        #expect(board.state(of: .accessibility) == .needed)
        #expect(board.state(of: .shortcut) == .done)
        #expect(!board.isComplete)
    }

    @Test func aGrantCompletesItsRowAlone() {
        let before = SetupBoard(dictionaries: 2, trusted: false, shortcutWorks: true)
        let after = SetupBoard(dictionaries: 2, trusted: true, shortcutWorks: true)
        #expect(before.state(of: .accessibility) == .needed)
        #expect(after.state(of: .accessibility) == .done)
        #expect(before.state(of: .dictionaries) == after.state(of: .dictionaries))
        #expect(after.isComplete)
    }

    @Test func aShortcutThatCannotRegisterIsAProblem() {
        let board = SetupBoard(dictionaries: 1, trusted: true, shortcutWorks: false)
        #expect(board.state(of: .shortcut) == .problem)
        #expect(!board.isComplete)
    }

    /// The rows are in the order the reader meets them, and each says something of its own in each state.
    @Test func eachRowSaysItsOwnState() {
        #expect(SetupBoard.Step.allCases == [.dictionaries, .accessibility, .shortcut])
        let needed = SetupBoard(dictionaries: 0, trusted: false, shortcutWorks: false)
        let done = SetupBoard(dictionaries: 3, trusted: true, shortcutWorks: true)
        var sentences: [String] = []
        for step in SetupBoard.Step.allCases {
            sentences.append(String(localized: SetupBoard.title(step)))
            sentences.append(String(localized: needed.detail(step)))
            sentences.append(String(localized: done.detail(step)))
        }
        #expect(Set(sentences).count == sentences.count, "\(sentences)")
        #expect(String(localized: done.detail(.dictionaries)) == "Dictionaries answering lookups: 3.")
    }

    /// **The setup window as the stage reads it from outside** (`keys ax`, lookup E2E G7, 2026-10-18): SwiftUI does not
    /// expose the rows to a walk from inside the app, so the setup checks read the external walk's nodes: every
    /// identifier, and the texts of the window's content (its first child), not its title bar.
    @Test func theSetupWindowIsReadFromTheExternalWalk() throws {
        func node(_ role: String, _ id: String = "", texts: [String] = [], depth: Int) -> [String: Any] {
            ["role": role, "id": id, "texts": texts, "depth": depth]
        }
        let nodes = [node("AXWindow", "setup", texts: ["Set Up XDict"], depth: 0), node("AXGroup", depth: 1),
                     node("AXGroup", "setup.dictionaries.needed", depth: 2),
                     node("AXStaticText", texts: ["词典"], depth: 3),
                     node("AXGroup", "setup.accessibility.done", depth: 2),
                     node("AXButton", "shortcut.recorder", texts: ["查词快捷键"], depth: 3),
                     node("AXStaticText", texts: ["Set Up XDict"], depth: 1)]
        let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "truncated": false])
        let read = try #require(SetupWindowReading.nodes(fromKeysAX: data))
        #expect(SetupWindowReading.identifiers(read).isSuperset(of: ["setup.dictionaries.needed",
                                                                    "setup.accessibility.done", "shortcut.recorder"]))
        #expect(SetupWindowReading.contentTexts(read) == ["词典", "查词快捷键"], "the title bar is not the content")
        #expect(SetupWindowReading.contentTexts([]).isEmpty)
        #expect(SetupWindowReading.nodes(fromKeysAX: Data("keys: no access".utf8)) == nil)
        #expect(SetupWindowReading.nodes(fromKeysAX: Data(#"{"nodes": [], "why": "no main window"}"#.utf8))?.isEmpty
            == true)
    }

    /// **`setup.chineseOnly` reads something before it passes**: an empty Accessibility tree has no English in it, and
    /// passed the check without the window having been read (lookup E2E diagnosis, 2026-10-18).
    @Test func chineseOnlyFailsWhenNothingWasRead() {
        #expect(!SetupLanguageCheck.chineseOnly(texts: [], preferredLanguage: "zh-Hans-CN"))
        #expect(SetupLanguageCheck.chineseOnly(texts: ["词典", "XDict 设置"], preferredLanguage: "zh-Hans-CN"))
        #expect(!SetupLanguageCheck.chineseOnly(texts: ["词典", "Accessibility"], preferredLanguage: "zh-Hans-CN"))
        #expect(!SetupLanguageCheck.chineseOnly(texts: ["词典"], preferredLanguage: "en-US"))
        #expect(SetupLanguageCheck.english(in: ["词典", "Add Dictionaries", "mdx"]) == ["Add Dictionaries"])
    }
}

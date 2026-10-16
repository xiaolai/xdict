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
}

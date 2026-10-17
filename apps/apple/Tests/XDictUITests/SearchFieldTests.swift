import AppKit
import Testing
@testable import XDictUI

/// **The search field's keys while an input method composes** (the toolbar move, Codex condition 5): Return, the arrows
/// and Escape belong to the input method while the field holds marked text, so a Chinese reader's candidates are not
/// taken for a lookup; with nothing marked they are the field's.
@MainActor
struct SearchFieldTests {
    final class Calls {
        var submitted = 0, moved: [Int] = [], cancelled = 0
    }

    static func coordinator(_ calls: Calls) -> SearchField.Coordinator {
        let coordinator = SearchField.Coordinator()
        coordinator.parent = SearchField(text: "", prompt: "Look Up", focus: 0, onChange: { _ in },
                                         onSubmit: { calls.submitted += 1 },
                                         onMove: { calls.moved.append($0); return true },
                                         onCancel: { calls.cancelled += 1; return true })
        return coordinator
    }

    @Test func returnArrowsAndEscapeAreTheInputMethodsWhileItComposes() {
        let calls = Calls()
        let coordinator = Self.coordinator(calls)
        let editor = NSTextView()
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)),
                         #selector(NSResponder.moveUp(_:)), #selector(NSResponder.cancelOperation(_:))] {
            #expect(!coordinator.control(NSSearchField(), textView: editor, doCommandBy: selector))
        }
        #expect(calls.submitted == 0 && calls.moved.isEmpty && calls.cancelled == 0)
    }

    @Test func withNothingMarkedTheKeysAreTheFields() {
        let calls = Calls()
        let coordinator = Self.coordinator(calls)
        let editor = NSTextView()
        #expect(!editor.hasMarkedText())
        #expect(coordinator.control(NSSearchField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(coordinator.control(NSSearchField(), textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(coordinator.control(NSSearchField(), textView: editor,
                                    doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(calls.submitted == 1 && calls.moved == [1] && calls.cancelled == 1)
    }
}

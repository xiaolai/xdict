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

    /// **The toolbar's idle search is a SwiftUI button** (owner, 2026-10-24: every toolbar icon is a SwiftUI toolbar
    /// button): an empty idle toolbar holds no editor; asking for the field presents the editor, expanded.
    @Test func anEmptyIdleSearchIsAButtonUntilAskedForTheKeyboard() async throws {
        let window = ToolbarFitTests.window(sidebar: false, subtitle: "", style: .unified, query: "")
        defer { window.close() }
        try await ToolbarFitTests.settle(window)
        let fields = (window.toolbar?.items ?? []).compactMap(\.view).compactMap {
            ToolbarFitTests.find(KeyboardSearchField.self, in: $0)
        }
        #expect(fields.isEmpty, "an empty idle search is the toolbar's button, not the editor")
        #expect((window.toolbar?.items ?? []).contains { $0.label == String(localized: "Search") },
                "the search item is still the toolbar's, named Search")
    }

    /// **An asked-for empty field never sticks open**: AppKit keeps a field editor when a window loses the keyboard, so
    /// losing the window itself must fold an empty field away (owner's window, 2026-10-24).
    @Test func losingTheWindowCollapsesAnEmptyAskedField() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 52),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let control = ToolbarSearchControl()
        window.contentView = control
        defer { window.close() }
        control.field.takeKeyboard()
        #expect(control.expanded)
        var ended = false
        control.onEditingEnded = { ended = true }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!control.expanded && ended, "the empty field stayed open after the window lost the keyboard")
    }

    /// Asking for the editor expands it; editing ending with nothing typed folds it away again.
    @Test func askingForTheKeyboardExpandsTheEditorAndEndingItCollapsesTheEmptyOne() {
        let control = ToolbarSearchControl()
        #expect(!control.expanded && control.field.isHidden)
        control.field.takeKeyboard()
        #expect(control.expanded && !control.field.isHidden)
        let coordinator = SearchField.Coordinator()
        control.field.delegate = coordinator
        coordinator.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: control.field))
        #expect(!control.expanded && control.field.isHidden)
    }

    @Test func textKeepsSearchExpandedAfterEditingEnds() {
        let control = ToolbarSearchControl()
        control.field.stringValue = "serendipity"
        control.prepareForFocus()
        control.endSearch()
        #expect(control.expanded && !control.field.isHidden)
        control.field.stringValue = ""
        control.refresh()
        #expect(!control.expanded && control.field.isHidden)
        control.prepareForFocus()
        #expect(control.expanded, "an empty field stays open while the reader is editing")
        control.endSearch()
        #expect(!control.expanded)
    }

    @Test func escapeClosesAnEmptySearchAndLeavesNonemptyClearingToTheNativeField() {
        let search = ToolbarSearchControl()
        let coordinator = SearchField.Coordinator()
        coordinator.parent = SearchField(text: "", prompt: "Search", focus: 0, onChange: { _ in },
                                         onSubmit: {}, onMove: { _ in false }, onCancel: { false })
        search.prepareForFocus()
        #expect(coordinator.control(search.field, textView: NSTextView(),
                                    doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!search.expanded)
        search.field.stringValue = "word"
        search.prepareForFocus()
        #expect(!coordinator.control(search.field, textView: NSTextView(),
                                     doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(search.expanded && search.field.stringValue == "word")
    }
}

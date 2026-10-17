import AppKit
import SwiftUI

/// **The search field**: AppKit's own `NSSearchField`, so it looks, reads to VoiceOver and edits as every Mac search
/// field does, with what the window needs on top — the keyboard whenever `focus` changes (at launch, and by Search,
/// ⌥⌘F: I1), Return to look up, ↑ and ↓ to move through suggestions or into the results, Escape to put suggestions away.
struct SearchField: NSViewRepresentable {
    let text: String
    let prompt: String
    /// The field takes the keyboard whenever this changes.
    let focus: Int
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    /// ↓ (+1) or ↑ (-1); answers whether it was used.
    let onMove: (Int) -> Bool
    /// Escape; answers whether it was used (otherwise the field clears itself, as a search field does).
    let onCancel: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> KeyboardSearchField {
        let field = KeyboardSearchField()
        field.placeholderString = prompt
        field.setAccessibilityIdentifier("search-field")
        field.setAccessibilityLabel(prompt)
        field.delegate = context.coordinator
        field.sendsWholeSearchString = true
        return field
    }

    func updateNSView(_ field: KeyboardSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            field.takeKeyboard()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField?
        var focus = 0

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent?.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // While an input method composes (marked text), its keys are its own: Return commits the candidate, the
            // arrows move among candidates, Escape cancels the composition (owner's toolbar move, Codex condition 5).
            if textView.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent?.onSubmit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                return parent?.onMove(1) ?? false
            case #selector(NSResponder.moveUp(_:)):
                return parent?.onMove(-1) ?? false
            case #selector(NSResponder.cancelOperation(_:)):
                return parent?.onCancel() ?? false
            default:
                return false
            }
        }
    }
}

/// A search field that can be asked for the keyboard before it is in a window, and takes it once it is.
final class KeyboardSearchField: NSSearchField {
    private var wantsKeyboard = false

    func takeKeyboard() {
        guard let window else {
            wantsKeyboard = true
            return
        }
        window.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }


    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsKeyboard, window != nil else { return }
        wantsKeyboard = false
        DispatchQueue.main.async { [weak self] in self?.takeKeyboard() }
    }
}

import AppKit
import SwiftUI
import XDictSearch

/// **The search field**: AppKit's own `NSSearchField`, so it looks, reads to VoiceOver and edits as every Mac search
/// field does, with what the window needs on top — the keyboard whenever `focus` changes (at launch, and by Search,
/// ⌥⌘F: I1), Return to look up, ↑ and ↓ to move through suggestions or into the results, Escape to put suggestions away.
/// Its magnifier drops down the scope menu (`SearchScopeMenu`, P6), and its placeholder names the chosen scope.
struct SearchField: NSViewRepresentable {
    let text: String
    let prompt: String
    /// The scope menu's lines; none, no menu.
    var scopes: [SearchScopeMenu.Item] = []
    /// A line of the scope menu chosen.
    var onScope: (SearchScope) -> Void = { _ in }
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
        if field.placeholderString != prompt {
            field.placeholderString = prompt
            field.setAccessibilityLabel(prompt)
        }
        if !scopes.isEmpty {
            field.showScopes(scopes, target: context.coordinator, action: #selector(Coordinator.choseScope(_:)))
        }
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            field.takeKeyboard()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate, NSMenuItemValidation {
        var parent: SearchField?
        var focus = 0

        @objc func choseScope(_ sender: NSMenuItem) {
            guard let choice = sender.representedObject as? SearchScopeMenu.Choice else { return }
            parent?.onScope(choice.scope)
        }

        func validateMenuItem(_ line: NSMenuItem) -> Bool {
            line.action == #selector(choseScope(_:)) ? SearchScopeMenu.validate(line) : true
        }

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
    /// The scope menu's lines last shown (`showScopes`), and AppKit's own magnifier, put back for every dictionary.
    var scopes: [SearchScopeMenu.Item] = []
    var plainMagnifier: NSImage?

    func takeKeyboard() {
        guard let window else {
            wantsKeyboard = true
            return
        }
        window.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }


    private var resizeObserver: (any NSObjectProtocol)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        if let window {
            DispatchQueue.main.async { [weak self] in self.map(ToolbarPriority.apply) }
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                                    object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self.map(ToolbarPriority.apply) }
            }
        }
        guard wantsKeyboard, window != nil else { return }
        wantsKeyboard = false
        DispatchQueue.main.async { [weak self] in self?.takeKeyboard() }
    }
}

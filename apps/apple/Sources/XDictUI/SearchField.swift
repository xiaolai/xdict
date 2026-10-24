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
    /// Editing ended: the toolbar's search control decides whether to collapse back to its button.
    var onEditingEnded: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ToolbarSearchControl {
        let control = ToolbarSearchControl()
        let field = control.field
        field.placeholderString = prompt
        field.setAccessibilityIdentifier("search-field")
        field.setAccessibilityLabel(prompt)
        field.delegate = context.coordinator
        field.sendsWholeSearchString = true
        // The editor is on screen because the reader asked for it (the toolbar's button, or the Search command), so it
        // takes the keyboard as soon as it has a window. An editor restored with a query and no ask (focus 0) does not.
        if focus > 0 { field.takeKeyboard() }
        context.coordinator.focus = focus
        control.onEditingEnded = { [weak coordinator = context.coordinator] in coordinator?.parent?.onEditingEnded() }
        return control
    }

    func updateNSView(_ control: ToolbarSearchControl, context: Context) {
        let field = control.field
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt {
            field.placeholderString = prompt
            field.setAccessibilityLabel(prompt)
        }
        if !scopes.isEmpty {
            field.showScopes(scopes, target: context.coordinator, action: #selector(Coordinator.choseScope(_:)))
        }
        control.refresh()
        // An initial empty window starts with the button. Only a later focus request (the Search command) opens it.
        if let previous = context.coordinator.focus, previous != focus { field.takeKeyboard() }
        context.coordinator.focus = focus
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate, NSMenuItemValidation {
        var parent: SearchField?
        var focus: Int?

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
            (field as? KeyboardSearchField)?.searchControl?.refresh()
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? KeyboardSearchField)?.searchControl?.prepareForFocus()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? KeyboardSearchField)?.searchControl?.endSearch()
            parent?.onEditingEnded()
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
                if parent?.onCancel() == true { return true }
                if let field = control as? KeyboardSearchField, field.stringValue.isEmpty,
                   let search = field.searchControl {
                    search.endSearch(resign: true)
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}

/// The search editor's own presentation: shown only while the reader is searching (a nonempty query or editing).
/// The idle magnifier is a SwiftUI toolbar button in `ToolbarSearchItem`, the same kind as the toolbar's other icons
/// (owner, 2026-10-24); the scope menu and keyboard handling are this editor's, unchanged.
final class ToolbarSearchControl: NSView {
    let field = KeyboardSearchField()
    private(set) var editing = false
    var expanded: Bool { editing || !field.stringValue.isEmpty }
    /// The item's SwiftUI side: an empty field the reader asked for folded away.
    var onEditingEnded: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.searchControl = self
        // **Finder's tall search field** (owner, 2026-10-24, Finder's own toolbar): the focus ring belongs to the field's
        // bezel, so the field fills the toolbar's height (macOS 26's extra-large) instead of sitting in it as a 26 pt
        // cell. The system draws the ring, around the field's outer capsule, as Finder's does.
        field.controlSize = .extraLarge
        addSubview(field)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: nil)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// **An asked-for empty field never sticks open** (2026-10-24): AppKit keeps a field editor when a window loses the
    /// keyboard, so end-editing may never arrive for a field the reader left empty; losing the window collapses it, as
    /// the toolbar's button did before it became a SwiftUI item. A nonempty query stays, and the ring goes with focus.
    @objc private func windowResignedKey(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        if field.stringValue.isEmpty {
            endSearch()
            onEditingEnded?()
        } else if editing {
            editing = false
            refresh()
        }
    }

    /// Expanded, the item is the width P5 asks for; collapsed, the control takes no room and the toolbar's button shows.
    override var intrinsicContentSize: NSSize {
        guard expanded else { return .zero }
        let width = window.map { ToolbarLayout.searchFieldWidth(window: $0.frame.width) }
            ?? ToolbarLayout.searchWidth.ideal
        return NSSize(width: width, height: field.fittingSize.height)
    }

    override func layout() {
        super.layout()
        field.frame = bounds
    }

    /// Leaving the toolbar: its item goes back to the button, so the width this editor asked for is released.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { ToolbarFieldWidth.release(field) }
    }

    func prepareForFocus() {
        editing = true
        refresh()
    }

    func endSearch(resign: Bool = false) {
        editing = false
        if resign, field.stringValue.isEmpty, field.currentEditor() != nil { window?.makeFirstResponder(nil) }
        refresh()
    }

    func refresh() {
        field.isHidden = !expanded
        invalidateIntrinsicContentSize()
        needsLayout = true
        if let window { ToolbarFieldWidth.watcher(of: window)?.update() }
    }
}

/// A search field that can be asked for the keyboard before it is in a window, and takes it once it is.
final class KeyboardSearchField: NSSearchField {
    weak var searchControl: ToolbarSearchControl?
    private var wantsKeyboard = false
    /// The scope menu's lines last shown (`showScopes`), and AppKit's own magnifier, put back for every dictionary.
    var scopes: [SearchScopeMenu.Item] = []
    var plainMagnifier: NSImage?

    func takeKeyboard() {
        searchControl?.prepareForFocus()
        guard let window else {
            wantsKeyboard = true
            return
        }
        window.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The toolbar item holding the field: last to go to the overflow (P8), as wide as the window asks (P5), named.
        // Its window's watcher follows every resize from then on, and the field coming back from the overflow lands here.
        if window != nil { DispatchQueue.main.async { [weak self] in self.map(ToolbarFieldWidth.attach) } }
        guard wantsKeyboard, window != nil else { return }
        wantsKeyboard = false
        DispatchQueue.main.async { [weak self] in self?.takeKeyboard() }
    }
}

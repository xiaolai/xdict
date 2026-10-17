import AppKit
import SwiftUI
import XDictEntryView

/// **Edit ▸ Find's keys, in the window they act on** (Apple parity P30, P33). SwiftUI shows the keys of a submenu's
/// items but does not send them (measured by the UI tour, 2026-10-17: ⌘F typed "f" into the search field), and Apple's
/// Find is a submenu. So the window takes them first: ⌘F, ⌘G, ⇧⌘G, ⌘E and ⌘J, while it is the key window; the menu
/// items stay, for the eye, the pointer and VoiceOver.
struct FindKeys: NSViewRepresentable {
    let state: SearchWindowState

    func makeNSView(context: Context) -> FindKeysView {
        let view = FindKeysView()
        view.state = state
        return view
    }

    func updateNSView(_ view: FindKeysView, context: Context) { view.state = state }
}

final class FindKeysView: NSView {
    var state: SearchWindowState?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors are called on the main thread, with the event the app is about to dispatch.
            let window = event.window, flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let taken = MainActor.assumeIsolated {
                guard let self, window === self.window else { return false }
                return self.handle(key: key, flags: flags)
            }
            return taken ? nil : event
        }
    }

    /// Whether the key was one of Find's, and was acted on.
    private func handle(key: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard let entry = state?.entry, entry.webView != nil else { return false }
        switch (key, flags) {
        case ("f", .command): entry.showFind()
        case ("g", .command): entry.stepFind(forward: true)
        case ("g", [.command, .shift]): entry.stepFind(forward: false)
        case ("e", .command): entry.useSelectionForFind()
        case ("j", .command): entry.jumpToSelection()
        default: return false
        }
        return true
    }
}

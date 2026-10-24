import AppKit
import SwiftUI
import XDictTokens

/// **A shortcut recorder — the one control every Settings row uses to take a key combination** (owner, 2026-10-24).
///
/// SwiftUI has no recorder, and `.onKeyPress` cannot stand in for one: a key press reaches the view only after the
/// menu's key equivalents have had it, so ⌘F would find instead of being recorded. Reading the combination first takes
/// a local `NSEvent` monitor, which is the one AppKit capability SwiftUI does not offer here, and the reason this is a
/// named type rather than a view body with AppKit in it.
///
/// Clicking starts it; the combination in use stands down meanwhile through `suspend`, so the reader can type it again.
/// Escape cancels. **Any click cancels and is consumed**: returned to the app, the click on the button itself would
/// find recording already stopped and start it again, so the recorder could never be cancelled with the mouse, and a
/// click anywhere else would both cancel and press what it landed on — a recording that ends with a side effect.
/// Every ending path restores `suspend(false)` exactly once.
struct ShortcutRecorderControl: View {
    /// What the button shows while it is not recording.
    let title: String
    /// What VoiceOver says for it while it is not recording.
    let spoken: Text
    let identifier: String
    /// Stand the combination in use down (true) and put it back (false).
    let suspend: (Bool) -> Void
    /// The key the reader typed, called once per recording, before the monitor stands down.
    let take: (NSEvent) -> Void

    @State private var monitor: Any?

    var body: some View {
        Button {  // placement: shortcut-field
            recording ? stop() : start()
        } label: {
            if recording {
                Text("Type Shortcut")
            } else {
                Text(verbatim: title)
            }
        }
        .frame(minWidth: Tokens.Control.shortcutFieldMin)
        .accessibilityLabel(recording ? Text("Type Shortcut") : spoken)
        .accessibilityIdentifier(identifier)
        .help(Text("Click, then type the combination to use"))
        .onDisappear { stop() }
    }

    private var recording: Bool { monitor != nil }

    private func start() {
        suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            guard event.type == .keyDown else {
                stop()
                return nil
            }
            // Escape alone cancels. Caps Lock and the other incidental flags are not part of the question: with Caps
            // Lock on, the old test for "no modifiers" was false and Escape was swallowed.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.intersection(ShortcutRecorderControl.modifiers).isEmpty {
                stop()
                return nil
            }
            // **The stand-down ends before the row records** (2026-10-24): the lookup row's refusal is its own feedback,
            // and restoring the hot key afterwards would re-register it and clear that refusal from under the reader.
            stop()
            take(event)
            return nil
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        suspend(false)
    }

    /// The modifiers a recorded combination may hold, in the order it is drawn: ⌃⌥⇧⌘. `nonisolated`: the preference
    /// layer reads it from outside the main actor.
    nonisolated static let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
}

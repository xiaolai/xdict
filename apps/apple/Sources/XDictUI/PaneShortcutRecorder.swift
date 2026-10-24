import AppKit
import SwiftUI

/// **The answer pane's toggle keys, recorded** (owner, 2026-10-24): the shared recorder, with the pane's own rules — the
/// combination XDict already uses is refused with a sentence, and the lookup hot key stands down while recording, so
/// typing it reaches the field instead of looking a word up.
struct PaneShortcutRecorder: View {
    @Binding var key: String
    @Binding var modifiers: Int
    /// Stands the lookup hot key down (true) and puts it back (false).
    let suspend: (Bool) -> Void
    /// Why the last combination was refused; nil once one is taken.
    @Binding var rejection: MeaningPanePreferences.ShortcutRejection?

    var body: some View {
        let current = MeaningPanePreferences.shortcut(key: key, modifiersRaw: modifiers)
        let label = MeaningPanePreferences.shortcutLabel(key: current.key, modifiers: current.modifiers)
        ShortcutRecorderControl(title: label,
                                spoken: Text("Answer pane shortcut, \(label)"),
                                identifier: "meaning-pane-shortcut",
                                suspend: suspend,
                                take: take)
    }

    private func take(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection(ShortcutRecorderControl.modifiers)
        let typed = (event.charactersIgnoringModifiers ?? "").lowercased()
        if let refusal = MeaningPanePreferences.rejection(key: typed, modifiers: flags) {
            rejection = refusal
            return
        }
        rejection = nil
        key = typed
        modifiers = Int(flags.rawValue)
    }
}

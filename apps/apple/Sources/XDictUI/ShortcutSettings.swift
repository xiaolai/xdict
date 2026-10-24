import AppKit
import SwiftUI
import XDictAnywhere

/// **Lookup from anywhere, in Settings** (plan-macos-v1 WI-8): the lookup shortcut — shown, rebindable by a recorder,
/// what went wrong said under it — and how else a selection reaches XDict (the Service, the menu bar). Rows, not a
/// form: they sit in the General pane (`GeneralSettings`; ADR-0012 d.1).
public struct ShortcutSettings: View {
    let registrar: ShortcutRegistrar

    public init(registrar: ShortcutRegistrar) {
        self.registrar = registrar
    }

    public var body: some View {
        Group {
            LabeledContent {
                ShortcutRecorder(registrar: registrar)
            } label: {
                Text("Look up the selection")
            }
            if let problem = registrar.problem {
                Text(AnywhereSentences.problem(problem))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("shortcut.problem")
            }
            Text("""
                Select a word in any app and press the shortcut: its entry opens in a panel beside it. Press Escape or \
                click elsewhere to close the panel, or the shortcut again to open it in XDict. You can also choose \
                Look Up in XDict when you Control-click a selection.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// **The lookup shortcut's row** (owner, 2026-10-24): the shared recorder (`ShortcutRecorderControl`) with the lookup
/// registrar's rules — it stands the hot key down while recording, and refuses what is unusable, reserved or already
/// taken, saying why under the row.
struct ShortcutRecorder: View {
    let registrar: ShortcutRegistrar

    var body: some View {
        ShortcutRecorderControl(title: registrar.current.label(),
                                spoken: Text("Lookup shortcut, \(ShortcutDisplay.spoken(registrar.current))"),
                                identifier: "shortcut.recorder",
                                suspend: { registrar.suspend($0) },
                                take: take)
    }

    private func take(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        registrar.choose(Shortcut(keyCode: event.keyCode, command: flags.contains(.command),
                                  option: flags.contains(.option), control: flags.contains(.control),
                                  shift: flags.contains(.shift)))
    }
}

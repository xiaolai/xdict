import AppKit
import SwiftUI
import XDictAnywhere

/// **Lookup from anywhere, in Settings** (plan-macos-v1 WI-8): the lookup shortcut — shown, rebindable by a recorder,
/// what went wrong said under it — and how else a selection reaches XDict (the Service, the menu bar). WI-9 builds the
/// rest of Settings around it.
public struct ShortcutSettings: View {
    let registrar: ShortcutRegistrar

    public init(registrar: ShortcutRegistrar) {
        self.registrar = registrar
    }

    public var body: some View {
        Form {
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
        .settingsPane()
    }
}

/// **A shortcut recorder**: a button showing the shortcut; clicked, it waits for the next combination typed — the
/// shortcut stood down meanwhile, so typing the one in use reaches the field — Escape or a click elsewhere cancels.
/// Every way recording ends puts the shortcut back (`ShortcutRegistrar.suspend`), once.
struct ShortcutRecorder: View {
    let registrar: ShortcutRegistrar
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            if recording {
                Text("Type Shortcut")
            } else {
                Text(verbatim: registrar.current.label())
            }
        }
        // One width either way, and a name VoiceOver can say (UI review S-06).
        .frame(minWidth: 140)
        .accessibilityLabel(recording ? Text("Type Shortcut")
                            : Text("Lookup shortcut, \(ShortcutDisplay.spoken(registrar.current))"))
        .accessibilityIdentifier("shortcut.recorder")
        .help(Text("Click, then type the combination to use"))
        .onDisappear { stop() }
    }

    private var recording: Bool { monitor != nil }

    private func start() {
        registrar.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            guard event.type == .keyDown else {
                stop()
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isEmpty {  // Escape alone: cancel
                stop()
                return nil
            }
            let chosen = Shortcut(keyCode: event.keyCode, command: flags.contains(.command), option: flags.contains(.option),
                                  control: flags.contains(.control), shift: flags.contains(.shift))
            stop()
            registrar.choose(chosen)
            return nil
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        registrar.suspend(false)
    }
}

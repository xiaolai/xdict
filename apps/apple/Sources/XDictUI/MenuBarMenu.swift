import AppKit
import SwiftUI
import XDictAnywhere

/// **The menu-bar item's menu** (plan-macos-v1 WI-8; XiaolaiDict's `MenuBarItem`, re-checked against the MDX-first
/// model): XDict has no reading history for a left click to open, so the item is a plain menu — look up the selection,
/// open the main window, Settings ▸ Dictionaries (ADR-0012 d.5), Settings, quit — with the shortcut's problem at its top when there is one, as the
/// menu is where a reader looks when the shortcut does nothing.
public struct MenuBarMenu: View {
    let registrar: ShortcutRegistrar
    let lookUp: () -> Void
    let openMain: () -> Void
    let showDictionaries: () -> Void
    @Environment(\.openSettings) private var openSettings

    public init(registrar: ShortcutRegistrar, lookUp: @escaping () -> Void, openMain: @escaping () -> Void,
                showDictionaries: @escaping () -> Void) {
        self.registrar = registrar
        self.lookUp = lookUp
        self.openMain = openMain
        self.showDictionaries = showDictionaries
    }

    public var body: some View {
        if let problem = registrar.problem {
            Text(AnywhereSentences.problem(problem))
            Divider()
        }
        // The shortcut drawn as the menu draws key equivalents, not written into the title (UI review A-07).
        if registrar.isRegistered, let key = ShortcutDisplay.keyEquivalent(registrar.current) {
            Button("Look Up Selection") { lookUp() }
                .keyboardShortcut(KeyEquivalent(key.key), modifiers: key.modifiers)
        } else {
            Button("Look Up Selection") { lookUp() }
        }
        Button("Open XDict") { openMain() }
        Button("Dictionaries…") { showDictionaries() }
        Divider()
        Button("Settings…") { openSettings() }
        Divider()
        Button("Quit XDict") { NSApplication.shared.terminate(nil) }
    }
}

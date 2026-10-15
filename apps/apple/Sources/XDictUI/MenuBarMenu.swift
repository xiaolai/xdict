import AppKit
import SwiftUI
import XDictAnywhere

/// **The menu-bar item's menu** (plan-macos-v1 WI-8; XiaolaiDict's `MenuBarItem`, re-checked against the MDX-first
/// model): XDict has no reading history for a left click to open, so the item is a plain menu — look up the selection,
/// open the main window, the library, Settings, quit — with the shortcut's problem at its top when there is one, as the
/// menu is where a reader looks when the shortcut does nothing.
public struct MenuBarMenu: View {
    let registrar: ShortcutRegistrar
    let lookUp: () -> Void
    let openMain: () -> Void
    let openLibrary: () -> Void
    @Environment(\.openSettings) private var openSettings

    public init(registrar: ShortcutRegistrar, lookUp: @escaping () -> Void, openMain: @escaping () -> Void,
                openLibrary: @escaping () -> Void) {
        self.registrar = registrar
        self.lookUp = lookUp
        self.openMain = openMain
        self.openLibrary = openLibrary
    }

    public var body: some View {
        if let problem = registrar.problem {
            Text(AnywhereSentences.problem(problem))
            Divider()
        }
        Button {
            lookUp()
        } label: {
            if registrar.isRegistered {
                Text("Look Up Selection (\(registrar.current.label()))")
            } else {
                Text("Look Up Selection")
            }
        }
        Button("Open XDict") { openMain() }
        Button("Library…") { openLibrary() }
        Divider()
        Button("Settings…") { openSettings() }
        Divider()
        Button("Quit XDict") { NSApplication.shared.terminate(nil) }
    }
}

import AppKit
import SwiftUI
import XDictAnywhere
import XDictCapture

/// **The menu-bar item's menu** (plan-macos-v1 WI-8; XiaolaiDict's `MenuBarItem`, re-checked against the MDX-first
/// model): XDict has no reading history for a left click to open, so the item is a plain menu — look up the selection,
/// open the main window, Settings ▸ Dictionaries (ADR-0012 d.5), Settings, quit — with the shortcut's problem at its top when there is one, as the
/// menu is where a reader looks when the shortcut does nothing. Since plan-capture WI-3, hover's pause group: Pause Hover
/// for a while, or when it resumes and Resume Hover (XiaolaiDict's `HoverPauseMenu`), from the control's one pause.
public struct MenuBarMenu: View {
    let registrar: ShortcutRegistrar
    let hover: HoverControl
    let lookUp: () -> Void
    let openMain: () -> Void
    let showDictionaries: () -> Void
    @Environment(\.openSettings) private var openSettings

    public init(registrar: ShortcutRegistrar, hover: HoverControl, lookUp: @escaping () -> Void,
                openMain: @escaping () -> Void, showDictionaries: @escaping () -> Void) {
        self.registrar = registrar
        self.hover = hover
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
            Button("Look Up Selection") { lookUp() }  // placement: menu-bar-extra
                .keyboardShortcut(KeyEquivalent(key.key), modifiers: key.modifiers)
        } else {
            Button("Look Up Selection") { lookUp() }  // placement: menu-bar-extra
        }
        Button("Open XDict") { openMain() }  // placement: menu-bar-extra
        Button("Dictionaries…") { showDictionaries() }  // placement: menu-bar-extra
        Divider()
        pauseGroup
        Divider()
        Button("Settings…") { openSettings() }  // placement: menu-bar-extra
        Divider()
        Button("Quit XDict") { NSApplication.shared.terminate(nil) }  // placement: menu-bar-extra
    }

    /// The pause group's lines, from the reader's setting and the control's one pause; with hover off, said rather than
    /// left out.
    @ViewBuilder private var pauseGroup: some View {
        let now = Date.now
        let entries = HoverPauseMenu.entries(for: hover, now: now)
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .pause:
                Menu(HoverSentences.pauseEntry(entry, now: now)) {  // placement: menu-bar-extra
                    ForEach(HoverPause.durations, id: \.self) { length in
                        Button { hover.pause(for: length) } label: { Text(HoverSentences.pauseLength(length)) }
                    }
                }
            case .resume:
                Button(HoverSentences.pauseEntry(entry, now: now)) { hover.resume() }  // placement: menu-bar-extra
            case .resumesAt, .hoverIsOff:
                Text(verbatim: HoverSentences.pauseEntry(entry, now: now))
            }
        }
    }
}

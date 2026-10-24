import AppKit
import Foundation
import SwiftUI
import XDictEntryView
import XDictSearch

/// **The main window's menus, as Apple's Dictionary has them** (parity P7, P33, P36; owner's decisions of 2026-10-17),
/// so the whole flow runs from the keyboard (R10). Edit ▸ Find holds Search For a New Word… (⌥⌘F), Find… (⌘F), Find
/// Next (⌘G), Find Previous (⇧⌘G), Use Selection for Find (⌘E) and Jump to Selection (⌘J); Search holds All
/// Dictionaries (⌘0), the first nine dictionaries (⌘1–9) and Select Next/Previous Dictionary (⌘} ⌘{); Go holds Back
/// (⌘[) and Forward (⌘]). XDict's own, kept by the ledger: Pronounce (⌥⌘P) in Edit, Return to Original Word (⌥⌘[) in
/// Go, and the View menu (HIG M17: every toolbar command in the menu bar), where Bigger and Smaller Text sit, with
/// Actual Size on ⌥⌘0 since ⌘0 is All Dictionaries. Each acts on the focused main window.
public struct SearchCommands: Commands {
    @FocusedValue(\.searchWindow) private var window
    /// The answer pane's toggle keys, as Settings ▸ General recorded them (owner, 2026-10-24).
    @AppStorage(MeaningPanePreferences.shortcutKey) private var paneShortcutKey = MeaningPanePreferences.defaultShortcutKey
    @AppStorage(MeaningPanePreferences.shortcutModifiersKey)
    private var paneShortcutModifiers = MeaningPanePreferences.defaultShortcutModifiers

    public init() {}

    /// The shortcut's one character, and the modifiers held with it — **through the one decoder** (owner, 2026-10-24):
    /// a corrupted preference reads back as the default rather than trapping on a negative integer.
    private var paneBinding: (key: String, modifiers: NSEvent.ModifierFlags) {
        MeaningPanePreferences.shortcut(key: paneShortcutKey, modifiersRaw: paneShortcutModifiers)
    }

    private var paneShortcut: KeyEquivalent {
        KeyEquivalent(paneBinding.key.first ?? Character(MeaningPanePreferences.defaultShortcutKey))
    }

    private var paneModifiers: EventModifiers {
        let flags = paneBinding.modifiers
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    public var body: some Commands {
        CommandGroup(replacing: .textEditing) {  // placement: P33
            Menu("Find") {
                Button("Search For a New Word…") { window?.focusSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(window == nil)
                Divider()
                Button("Find…") { window?.entry.showFind() }
                    .keyboardShortcut("f")
                    .disabled(window?.hasEntry != true)
                Button("Find Next") { window?.entry.stepFind(forward: true) }
                    .keyboardShortcut("g")
                    .disabled(window?.hasEntry != true)
                Button("Find Previous") { window?.entry.stepFind(forward: false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(window?.hasEntry != true)
                Button("Use Selection for Find") { window?.entry.useSelectionForFind() }
                    .keyboardShortcut("e")
                    .disabled(window?.hasEntry != true)
                Button("Jump to Selection") { window?.entry.jumpToSelection() }
                    .keyboardShortcut("j")
                    .disabled(window?.hasEntry != true)
            }
            Divider()
            Button("Pronounce") { window?.pronounceSelectionOrShown() }  // placement: P48
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(window?.canPronounce != true)
        }
        CommandMenu("Go") {  // placement: P35
            Button("Back") { window?.model.back() }
                .keyboardShortcut("[")
                .disabled(window?.model.canGoBack != true)
            Button("Forward") { window?.model.forward() }
                .keyboardShortcut("]")
                .disabled(window?.model.canGoForward != true)
            Button("Return to Original Word") { window?.model.returnToOrigin() }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(window?.model.canReturnToOrigin != true)
            // **A sense chosen from the keyboard** (HIG audit UI21, UI22): only while a captured sentence is held, as a
            // click is.
            Divider()
            Button("Next Sense") { window?.stepSense(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(window?.meaning.canAsk != true)
            Button("Previous Sense") { window?.stepSense(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(window?.meaning.canAsk != true)
            Button("Clear Chosen Sense") { window?.clearSense() }
                .disabled(window?.meaning.hasSenseSelection != true)
            // **The All page's dictionaries** (HIG audit UI24): the one being read is checked; choosing another jumps
            // the page to it, so a long page is never only scrolled through. Not a second list to manage them in.
            Divider()
            Menu("Dictionaries on This Page") {
                ForEach(window?.pageSources?.sources ?? [], id: \.id) { source in
                    Toggle(isOn: onPage(source.id)) { Text(verbatim: source.name) }
                }
            }
            .disabled((window?.pageSources?.sources.count ?? 0) < 2)
        }
        CommandMenu("Search") {  // placement: P36
            Toggle(isOn: scoped(.all)) { Text(SearchSentences.allDictionaries) }
                .keyboardShortcut(ScopeShortcut.all, modifiers: .command)
            let enabled = window?.model.known.filter(\.enabled) ?? []
            if !enabled.isEmpty { Divider() }
            ForEach(Array(enabled.enumerated()), id: \.element.id) { index, source in
                if let key = ScopeShortcut.dictionary(index) {
                    Toggle(isOn: scoped(.one(source.id))) { Text(verbatim: source.name) }
                        .keyboardShortcut(key, modifiers: .command)
                        .disabled(source.handle == nil)
                } else {
                    Toggle(isOn: scoped(.one(source.id))) { Text(verbatim: source.name) }
                        .disabled(source.handle == nil)
                }
            }
            Divider()
            Button("Select Next Dictionary") { window?.model.stepScope(forward: true) }
                .keyboardShortcut(ScopeShortcut.next, modifiers: .command)
                .disabled(window == nil)
            Button("Select Previous Dictionary") { window?.model.stepScope(forward: false) }
                .keyboardShortcut(ScopeShortcut.previous, modifiers: .command)
                .disabled(window == nil)
        }
        CommandGroup(after: .toolbar) {  // placement: P34
            // **Each pane has a command** (HIG audit UI02, UI07): the results list after a search, the answer pane
            // always, so a closed pane comes back without a new ask.
            Button(window?.resultsShown == true ? LocalizedStringKey("Hide Results") : LocalizedStringKey("Show Results")) {
                window?.panes.toggleResults()
            }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(window?.model.listing == nil)
            Button(window?.panes.meaningShown == true ? LocalizedStringKey("Hide Meaning in Context")
                   : LocalizedStringKey("Show Meaning in Context")) {
                window?.panes.toggleMeaning()
            }
            .keyboardShortcut(paneShortcut, modifiers: paneModifiers)
            .disabled(window == nil)
            Divider()
            Button("Bigger Text") { window?.entry.zoomIn() }
                .keyboardShortcut("+")
                .disabled(window == nil)
            Button("Smaller Text") { window?.entry.zoomOut() }
                .keyboardShortcut("-")
                .disabled(window == nil)
            Button("Actual Size") { window?.entry.resetZoom() }
                .keyboardShortcut(ScopeShortcut.actualSize, modifiers: [.command, .option])
                .disabled(window == nil)
            Button("Expand All") { window?.entry.expandAll(true) }
                .disabled(window?.hasEntry != true)
            Button("Collapse All") { window?.entry.expandAll(false) }
                .disabled(window?.hasEntry != true)
            // The current choice checked (UI review A-08).
            Picker(selection: Binding(get: { window?.entry.theme ?? .matchApp }, set: { window?.entry.setTheme($0) })) {
                ForEach(EntryTheme.allCases, id: \.self) { theme in
                    Text(EntrySentences.theme(theme)).tag(theme)
                }
            } label: {
                Text("Entry Appearance")
            }
            .pickerStyle(.menu)
            .disabled(window?.hasEntry != true)
            Divider()
        }
        // File ▸ Print… (P32, P44): the shown entry.
        CommandGroup(replacing: .printItem) {  // placement: P32
            Button("Print…") { window?.entry.printEntry() }
                .keyboardShortcut("p")
                .disabled(window?.hasEntry != true)
        }
    }

    /// A menu item's check for a scope, which choosing sets.
    private func onPage(_ id: UUID) -> Binding<Bool> {
        Binding(get: { window?.pageSources?.current == id }, set: { chosen in if chosen { window?.jumpToSource(id) } })
    }

    private func scoped(_ scope: SearchScope) -> Binding<Bool> {
        Binding(get: { window?.model.scope == scope }, set: { chosen in if chosen { window?.model.setScope(scope) } })
    }
}

/// **The Search menu's keys** (P7): Apple's, ⌘0 for every dictionary and ⌘1–⌘9 for the first nine, ⌘} and ⌘{ to step;
/// Actual Size moves off ⌘0 to ⌥⌘0.
public enum ScopeShortcut {
    public static let all: KeyEquivalent = "0"
    public static let next: KeyEquivalent = "}"
    public static let previous: KeyEquivalent = "{"
    public static let actualSize: KeyEquivalent = "0"

    /// ⌘1 for the first enabled dictionary, up to ⌘9 for the ninth; none after.
    public static func dictionary(_ index: Int) -> KeyEquivalent? {
        guard (0..<9).contains(index) else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }
}

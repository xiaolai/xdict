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

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Search For a New Word…") { window?.focusSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(window == nil)
                Divider()
                Button("Find…") { window?.entry.showFind() }
                    .keyboardShortcut("f")
                    .disabled(window?.entry.webView == nil)
                Button("Find Next") { window?.entry.stepFind(forward: true) }
                    .keyboardShortcut("g")
                    .disabled(window?.entry.webView == nil)
                Button("Find Previous") { window?.entry.stepFind(forward: false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(window?.entry.webView == nil)
                Button("Use Selection for Find") { window?.entry.useSelectionForFind() }
                    .keyboardShortcut("e")
                    .disabled(window?.entry.webView == nil)
                Button("Jump to Selection") { window?.entry.jumpToSelection() }
                    .keyboardShortcut("j")
                    .disabled(window?.entry.webView == nil)
            }
            Divider()
            Button("Pronounce") { window?.pronounceShown() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(window?.canPronounce != true)
        }
        CommandMenu("Go") {
            Button("Back") { window?.model.back() }
                .keyboardShortcut("[")
                .disabled(window?.model.canGoBack != true)
            Button("Forward") { window?.model.forward() }
                .keyboardShortcut("]")
                .disabled(window?.model.canGoForward != true)
            Button("Return to Original Word") { window?.model.returnToOrigin() }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(window?.model.canReturnToOrigin != true)
        }
        CommandMenu("Search") {
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
        CommandGroup(after: .toolbar) {
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
                .disabled(window?.entry.webView == nil)
            Button("Collapse All") { window?.entry.expandAll(false) }
                .disabled(window?.entry.webView == nil)
            // The current choice checked (UI review A-08).
            Picker(selection: Binding(get: { window?.entry.theme ?? .matchApp }, set: { window?.entry.setTheme($0) })) {
                ForEach(EntryTheme.allCases, id: \.self) { theme in
                    Text(EntrySentences.theme(theme)).tag(theme)
                }
            } label: {
                Text("Entry Appearance")
            }
            .pickerStyle(.menu)
            .disabled(window?.entry.webView == nil)
            Divider()
        }
        // File ▸ Print… (P32, P44): the shown entry.
        CommandGroup(replacing: .printItem) {
            Button("Print…") { window?.entry.printEntry() }
                .keyboardShortcut("p")
                .disabled(window?.entry.webView == nil)
        }
    }

    /// A menu item's check for a scope, which choosing sets.
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

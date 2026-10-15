import SwiftUI
import XDictEntryView
import XDictSearch

/// **The main window's menus**, so the whole flow runs from the keyboard (R10): Go (Back ⌘[, Forward ⌘], Return to
/// Original Word ⌥⌘[, Search ⌥⌘F), Dictionaries (every one ⌥⌘0, the first nine ⌥⌘1–9), find in the entry (⌘F, ⌘G,
/// ⇧⌘G) and Pronounce (⌥⌘P, WI-7) in Edit, and zoom and appearance in View. Each acts on the focused main window.
public struct SearchCommands: Commands {
    @FocusedValue(\.searchWindow) private var window

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Button("Find in Entry…") { window?.entry.showFind() }
                .keyboardShortcut("f")
                .disabled(window?.entry.webView == nil)
            Button("Find Next") { window?.entry.stepFind(forward: true) }
                .keyboardShortcut("g")
                .disabled(window?.entry.webView == nil)
            Button("Find Previous") { window?.entry.stepFind(forward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(window?.entry.webView == nil)
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
            Divider()
            Button("Search") { window?.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(window == nil)
        }
        CommandMenu("Dictionaries") {
            Toggle(isOn: scoped(.all)) { Text(SearchSentences.allDictionaries) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            let enabled = window?.model.known.filter(\.enabled) ?? []
            if !enabled.isEmpty { Divider() }
            ForEach(Array(enabled.enumerated()), id: \.element.id) { index, source in
                if index < 9 {
                    Toggle(isOn: scoped(.one(source.id))) { Text(verbatim: source.name) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                } else {
                    Toggle(isOn: scoped(.one(source.id))) { Text(verbatim: source.name) }
                }
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { window?.entry.zoomIn() }
                .keyboardShortcut("+")
                .disabled(window?.entry.webView == nil)
            Button("Zoom Out") { window?.entry.zoomOut() }
                .keyboardShortcut("-")
                .disabled(window?.entry.webView == nil)
            Button("Actual Size") { window?.entry.resetZoom() }
                .keyboardShortcut("0")
                .disabled(window?.entry.webView == nil)
            Menu("Entry Appearance") {
                ForEach(EntryTheme.allCases, id: \.self) { theme in
                    Button(EntrySentences.theme(theme)) { window?.entry.setTheme(theme) }
                }
            }
            .disabled(window?.entry.webView == nil)
            Divider()
        }
    }

    /// A menu item's check for a scope, which choosing sets.
    private func scoped(_ scope: SearchScope) -> Binding<Bool> {
        Binding(get: { window?.model.scope == scope }, set: { chosen in if chosen { window?.model.setScope(scope) } })
    }
}

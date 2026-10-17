import SwiftUI
import XDictAnywhere

/// **The lookup shortcut as a menu shows it and as VoiceOver says it** (UI review A-07, S-06): a key equivalent drawn
/// right-aligned by the menu, not written into the item's title; and "Control-Option-D", not "⌃⌥D".
public enum ShortcutDisplay {
    /// The key and modifiers for `.keyboardShortcut`, when the key is one the layout types; nil for keys a menu cannot
    /// draw from a character (function keys, arrows), which then go without.
    public static func keyEquivalent(_ shortcut: Shortcut, keyName: (UInt32) -> String? = Shortcut.currentLayoutName)
        -> (key: Character, modifiers: SwiftUI.EventModifiers)? {
        guard let name = keyName(shortcut.keyCode), name.count == 1, let key = name.lowercased().first,
              key.isLetter || key.isNumber || key.isPunctuation || key.isSymbol else { return nil }
        var modifiers: SwiftUI.EventModifiers = []
        if shortcut.control { modifiers.insert(.control) }
        if shortcut.option { modifiers.insert(.option) }
        if shortcut.shift { modifiers.insert(.shift) }
        if shortcut.command { modifiers.insert(.command) }
        return (key, modifiers)
    }

    /// The combination spoken: modifier names in macOS's order, then the key as the menu labels it.
    public static func spoken(_ shortcut: Shortcut, keyName: (UInt32) -> String? = Shortcut.currentLayoutName) -> String {
        let names: [(Bool, String)] = [(shortcut.control, String(localized: "Control")),
                                       (shortcut.option, String(localized: "Option")),
                                       (shortcut.shift, String(localized: "Shift")),
                                       (shortcut.command, String(localized: "Command"))]
        let label = shortcut.label(keyName: keyName)
        let key = label.drop { "⌃⌥⇧⌘".contains($0) }
        return (names.filter(\.0).map(\.1) + [String(key)]).joined(separator: "-")
    }
}

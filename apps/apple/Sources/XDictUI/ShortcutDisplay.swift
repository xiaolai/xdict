import Carbon.HIToolbox
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
        if shortcut.modifiers & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if shortcut.modifiers & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        return (key, modifiers)
    }

    /// The combination spoken: modifier names in macOS's order, then the key as the menu labels it.
    public static func spoken(_ shortcut: Shortcut, keyName: (UInt32) -> String? = Shortcut.currentLayoutName) -> String {
        let names: [(Int, String)] = [(controlKey, String(localized: "Control")), (optionKey, String(localized: "Option")),
                                      (shiftKey, String(localized: "Shift")), (cmdKey, String(localized: "Command"))]
        let label = shortcut.label(keyName: keyName)
        let key = label.drop { "⌃⌥⇧⌘".contains($0) }
        return (names.filter { shortcut.modifiers & UInt32($0.0) != 0 }.map(\.1) + [String(key)]).joined(separator: "-")
    }
}

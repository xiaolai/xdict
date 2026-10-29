import AppKit
import Foundation
import XDictTokens

/// **The answer pane's own preferences** (owner, 2026-10-24: gap, width, opening time and shortcut are the reader's).
/// The tokens are the defaults; Settings ▸ General writes the same keys, and the pane reads them when it opens. Every
/// accessor holds a stored value to what Settings offers — a hand-edited or corrupted preference never becomes one.
public enum MeaningPanePreferences {
    public static let gapKey = "meaningPane.gap"
    public static let widthKey = "meaningPane.width"
    public static let animationKey = "meaningPane.animationSeconds"
    public static let shortcutKey = "meaningPane.shortcutKey"
    public static let shortcutModifiersKey = "meaningPane.shortcutModifiers"

    public static let defaultGap = Double(Tokens.Window.paneGap)
    public static let defaultWidth = Double(Tokens.Window.meaningPaneIdeal)
    public static let defaultAnimation = Double(Tokens.Motion.meaningPaneOpen)
    public static let defaultShortcutKey = "i"
    public static let defaultShortcutModifiers = Int(NSEvent.ModifierFlags.command.rawValue)

    public static let gapRange: ClosedRange<Double> = 0...Double(Tokens.Window.paneGapMax)
    public static let widthRange: ClosedRange<Double> =
        Double(Tokens.Window.meaningPaneMin) ... Double(Tokens.Window.meaningPaneMax)
    public static let animationRange: ClosedRange<Double> = 0...Double(Tokens.Motion.meaningPaneOpenMax)

    /// The air between the main window and the pane, in points.
    public static func gap(_ defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.object(forKey: gapKey) as? Double ?? defaultGap
        return CGFloat(clamped(stored, in: gapRange, fallback: defaultGap))
    }

    /// The pane's width, in points.
    public static func width(_ defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.object(forKey: widthKey) as? Double ?? defaultWidth
        return CGFloat(clamped(stored, in: widthRange, fallback: defaultWidth))
    }

    /// The drawer's opening time, in seconds; zero opens without animation.
    public static func animation(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let stored = defaults.object(forKey: animationKey) as? Double ?? defaultAnimation
        return clamped(stored, in: animationRange, fallback: defaultAnimation)
    }

    /// The toggle shortcut, read from the reader's defaults.
    public static func shortcut(_ defaults: UserDefaults = .standard) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        shortcut(key: defaults.string(forKey: shortcutKey) ?? defaultShortcutKey,
                 modifiersRaw: defaults.object(forKey: shortcutModifiersKey) as? Int ?? defaultShortcutModifiers)
    }

    /// **The one decoder of a stored shortcut**, used by the menu, the recorder and the tests alike, so a stored value
    /// that is not a shortcut — a negative modifier integer, a bare key, no ⌘/⌃/⌥ — reads back as the default rather
    /// than trapping or arming a key that fires while the reader types.
    public static func shortcut(key storedKey: String, modifiersRaw: Int) -> (key: String,
                                                                           modifiers: NSEvent.ModifierFlags) {
        let defaultFlags = NSEvent.ModifierFlags(rawValue: UInt(defaultShortcutModifiers))
        // `UInt(_:)` traps on a negative integer: a corrupted preference must not crash the app.
        let raw = UInt32(exactly: modifiersRaw) ?? 0
        let held = NSEvent.ModifierFlags(rawValue: UInt(raw)).intersection(ShortcutRecorderControl.modifiers)
        let typed = storedKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard typed.count == 1, holdsCommand(held) else { return (defaultShortcutKey, defaultFlags) }
        return (typed, held)
    }

    /// "⌘I", the shortcut as the reader sees it.
    public static func shortcutLabel(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        return label + key.uppercased()
    }

    /// **Why XDict will not take a combination for the pane.** A menu shortcut the app already binds can never fire
    /// (⌘F reaches Find first), and one without ⌘, ⌃ or ⌥ would fire while the reader types.
    public struct ShortcutRejection: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case notAKey
            case needsCommand
            case taken
        }

        public let reason: Reason
        /// The XDict command already holding the combination, when that is the reason.
        public let command: String?
    }

    /// Nil when the combination can be the pane's; otherwise why it cannot.
    public static func rejection(key: String, modifiers: NSEvent.ModifierFlags) -> ShortcutRejection? {
        let typed = key.lowercased()
        guard typed.count == 1, let character = typed.first,
              character.isLetter || character.isNumber || character.isPunctuation || character.isSymbol else {
            return ShortcutRejection(reason: .notAKey, command: nil)
        }
        let held = modifiers.intersection(ShortcutRecorderControl.modifiers)
        guard holdsCommand(held) else { return ShortcutRejection(reason: .needsCommand, command: nil) }
        if let command = taken.first(where: {
            $0.key == typed && sameChord($0.modifiers, held, character: character)
        }) {
            return ShortcutRejection(reason: .taken, command: String(localized: command.command))
        }
        return nil
    }

    /// **The shift a character needs to be typed is not an extra modifier** (2026-10-24): on most layouts `{`, `}` and
    /// `+` can only be typed with shift, and the menu binds that chord — ⌘{ is typed ⇧⌘[, and the event the recorder sees
    /// carries the shift. So for a punctuation mark or a symbol the shift bit is compared both ways. A letter or a
    /// number keeps it: ⇧⌘F is not ⌘F, and stays available.
    private static func sameChord(_ listed: NSEvent.ModifierFlags, _ held: NSEvent.ModifierFlags,
                                  character: Character) -> Bool {
        if listed == held { return true }
        guard character.isPunctuation || character.isSymbol else { return false }
        return listed == held.subtracting(.shift) || held == listed.subtracting(.shift)
    }

    /// What to say under the row when the combination is refused.
    public static func sentence(_ rejection: ShortcutRejection) -> String {
        switch rejection.reason {
        case .notAKey:
            String(localized: "That key cannot be a menu shortcut. Use a letter, a number or a symbol.")
        case .needsCommand:
            String(localized: "Hold ⌘, ⌃ or ⌥ with the key, or it would fire while you type.")
        case .taken:
            String(localized: "XDict already uses this combination for \(rejection.command ?? "")")
        }
    }

    /// One command XDict's menus already answer to.
    private struct TakenCommand {
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let command: LocalizedStringResource

        init(_ key: String, _ modifiers: NSEvent.ModifierFlags, _ command: LocalizedStringResource) {
            self.key = key
            self.modifiers = modifiers
            self.command = command
        }
    }

    /// **The combinations the pane may not take** — XDict's own menu commands (`SearchCommands`) and the standard
    /// editing, window and app commands its menus carry. Not the system-wide reserved list a *global* hot key is held
    /// to: a menu shortcut acts only inside XDict's windows, and ⌘I, which that list reserves for Italic elsewhere,
    /// is the pane's own default.
    private static let taken: [TakenCommand] = [
        // Edit and text: what a reader's hands expect everywhere.
        TakenCommand("z", [.command], "Undo"), TakenCommand("z", [.command, .shift], "Redo"),
        TakenCommand("x", [.command], "Cut"), TakenCommand("c", [.command], "Copy"),
        TakenCommand("v", [.command], "Paste"), TakenCommand("a", [.command], "Select All"),
        // File, window and app. ⌘N is the File menu's own New Window (SwiftUI's `.newItem`, which New Tab is placed after).
        TakenCommand("p", [.command], "Print"), TakenCommand("w", [.command], "Close"),
        TakenCommand("n", [.command], "New Window"),
        TakenCommand("t", [.command], "New Tab"), TakenCommand("o", [.command], "Add Dictionaries…"),
        TakenCommand("m", [.command], "Minimize"), TakenCommand("q", [.command], "Quit"),
        TakenCommand("h", [.command], "Hide XDict"), TakenCommand("h", [.command, .option], "Hide Others"),
        TakenCommand(",", [.command], "Settings"),
        // XDict's Find and Pronounce (`SearchCommands`).
        TakenCommand("f", [.command], "Find"), TakenCommand("f", [.command, .option], "Search For a New Word"),
        TakenCommand("g", [.command], "Find Next"), TakenCommand("g", [.command, .shift], "Find Previous"),
        TakenCommand("e", [.command], "Use Selection for Find"), TakenCommand("j", [.command], "Jump to Selection"),
        TakenCommand("p", [.command, .option], "Pronounce"),
        // Go.
        TakenCommand("[", [.command], "Back"), TakenCommand("]", [.command], "Forward"),
        TakenCommand("[", [.command, .option], "Return to Original Word"),
        // Search: every dictionary, the first nine, and stepping.
        TakenCommand("0", [.command], "All Dictionaries"),
        TakenCommand("0", [.command, .option], "Actual Size"),
        TakenCommand("}", [.command], "Select Next Dictionary"),
        TakenCommand("{", [.command], "Select Previous Dictionary"),
        TakenCommand("1", [.command], "Dictionary 1"), TakenCommand("2", [.command], "Dictionary 2"),
        TakenCommand("3", [.command], "Dictionary 3"), TakenCommand("4", [.command], "Dictionary 4"),
        TakenCommand("5", [.command], "Dictionary 5"), TakenCommand("6", [.command], "Dictionary 6"),
        TakenCommand("7", [.command], "Dictionary 7"), TakenCommand("8", [.command], "Dictionary 8"),
        TakenCommand("9", [.command], "Dictionary 9"),
        // View: text size, the results list, the pane itself (hidden while a shortcut is being chosen).
        TakenCommand("+", [.command], "Bigger Text"), TakenCommand("-", [.command], "Smaller Text"),
        TakenCommand("s", [.command, .control], "Show Results"),
    ]

    /// ⌘, ⌃ or ⌥ is required; ⇧ alone would fire while typing.
    private static func holdsCommand(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    /// The value held to `range`; a non-finite one becomes `fallback`, never geometry.
    static func clamped(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

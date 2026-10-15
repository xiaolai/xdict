import Carbon.HIToolbox
import Foundation
import Testing
import XDictAnywhere

/// The shortcut as data: what can be saved, loaded and labelled without trapping, and which combinations the reader
/// may not take from every other app. Moved from XiaolaiDict (`ShortcutTests`, both of its targets) with the code.
struct ShortcutTests {
    private func name(_ keyCode: UInt32) -> String? { keyCode == UInt32(kVK_ANSI_D) ? "d" : nil }

    /// The label is derived from the combination actually registered, modifiers in the system's order.
    @Test func theLabelFollowsTheCombination() {
        #expect(Shortcut.defaultLookUp.label(keyName: name) == "⌃⌥D")
        let all = Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(all.label(keyName: name) == "⌃⌥⇧⌘D")
        #expect(Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey)).label(keyName: name) == "⌘F5")
    }

    /// The default the plan names: ⌃⌥D.
    @Test func theDefaultIsControlOptionD() {
        #expect(Shortcut.defaultLookUp == Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey)))
    }

    @Test func aShortcutNeedsCommandControlOrOption() {
        #expect(Shortcut.defaultLookUp.isUsable)
        #expect(!Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: 0).isUsable)
        #expect(!Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(shiftKey)).isUsable)
    }

    /// **A key code no keyboard has is not a shortcut**: labelling one past 65,535 trapped in XiaolaiDict.
    @Test func aKeyCodeNoKeyboardHasIsNotUsable() {
        #expect(!Shortcut(keyCode: 70_000, modifiers: UInt32(cmdKey)).isUsable)
        #expect(!Shortcut(keyCode: 0x80, modifiers: UInt32(cmdKey)).isUsable)
        #expect(Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey)).isUsable)
        #expect(Shortcut.currentLayoutName(70_000) == nil)
    }

    @Test func aChosenShortcutIsKept() throws {
        let store = ShortcutStore(defaults: try Self.scratchDefaults())
        #expect(store.load() == .defaultLookUp)
        let chosen = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey))
        try store.save(chosen)
        #expect(store.load() == chosen)
    }

    /// An unusable saved shortcut — edited by hand, or corrupt — is not registered: the default is.
    @Test func anUnusableOrCorruptSavedShortcutFallsBackToTheDefault() throws {
        let defaults = try Self.scratchDefaults()
        let store = ShortcutStore(defaults: defaults)
        try store.save(Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: 0))
        #expect(store.load() == .defaultLookUp)
        defaults.set(try JSONEncoder().encode(Shortcut(keyCode: 70_000, modifiers: UInt32(cmdKey))), forKey: ShortcutStore.key)
        #expect(store.load() == .defaultLookUp)
        defaults.set(Data("not json".utf8), forKey: ShortcutStore.key)
        #expect(store.load() == .defaultLookUp)
    }

    /// The layout answers keypad Enter and Clear with control characters, which print as nothing in a menu.
    @Test func keypadEnterAndClearHaveTheirOwnLabels() {
        let control: (UInt32) -> String? = { $0 == UInt32(kVK_ANSI_KeypadEnter) ? "\u{3}" : "\u{1B}" }
        #expect(Shortcut(keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: UInt32(cmdKey)).label(keyName: control) == "⌘⌤")
        #expect(Shortcut(keyCode: UInt32(kVK_ANSI_KeypadClear), modifiers: UInt32(cmdKey)).label(keyName: control) == "⌘⌧")
    }

    /// **The mask, not the bit number**: `kUCKeyTranslateNoDeadKeysBit` is 0, which asked for no option at all.
    @Test func deadKeysAreSuppressedWithTheMask() {
        #expect(Shortcut.layoutTranslationOptions == OptionBits(kUCKeyTranslateNoDeadKeysMask))
        #expect(Shortcut.layoutTranslationOptions != 0)
    }

    // MARK: - Reserved combinations

    private static let qwerty: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_F: "f", kVK_ANSI_H: "h",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q",
        kVK_ANSI_S: "s", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Z: "z",
        kVK_ANSI_Comma: ",", kVK_ANSI_J: "j", kVK_ANSI_3: "3",
    ]
    private static func us(_ code: UInt32) -> String? { qwerty[Int(code)] }

    private func reserved(_ key: Int, _ modifiers: Int, layout: (UInt32) -> String? = us) -> Bool {
        Shortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers)).isReserved(keyName: layout)
    }

    /// **The standard commands cannot become the lookup shortcut**: a registered hot key is taken before any app sees
    /// the key, so ⌘C recorded by a mis-press would look a word up in every app instead of copying.
    @Test func theStandardCommandsAreReserved() {
        for key in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_S,
                    kVK_ANSI_F, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_Comma, kVK_Tab,
                    kVK_Space] {
            #expect(reserved(key, cmdKey), "⌘ with key code \(key) was accepted as a global hot key")
            #expect(Shortcut(keyCode: UInt32(key), modifiers: UInt32(cmdKey)).isUsable)
        }
    }

    @Test func theSystemsOwnCombinationsAreReserved() {
        #expect(reserved(kVK_ANSI_Z, cmdKey | shiftKey))
        #expect(reserved(kVK_ANSI_3, cmdKey | shiftKey))
        #expect(reserved(kVK_Escape, cmdKey | optionKey))
        #expect(reserved(kVK_ANSI_Q, cmdKey | controlKey))
        #expect(reserved(kVK_Space, controlKey))
        #expect(reserved(kVK_Space, cmdKey | optionKey))
    }

    /// Exact modifiers, not "contains ⌘": the default's neighbours stay free.
    @Test func theSameKeyWithOtherModifiersIsFree() {
        #expect(!reserved(kVK_ANSI_C, cmdKey | optionKey))
        #expect(!reserved(kVK_ANSI_C, controlKey | optionKey))
        #expect(!reserved(kVK_ANSI_J, cmdKey))
        #expect(!reserved(kVK_F5, cmdKey))
        #expect(!Shortcut.defaultLookUp.isReserved(keyName: Self.us))
    }

    /// By the character the key types, not where it sits: on Dvorak QWERTY's I types C.
    @Test func reservationFollowsTheLayout() {
        let dvorak: (UInt32) -> String? = { code in
            switch Int(code) {
            case kVK_ANSI_I: "c"
            case kVK_ANSI_C: "j"
            default: nil
            }
        }
        #expect(reserved(kVK_ANSI_I, cmdKey, layout: dvorak))
        #expect(!reserved(kVK_ANSI_C, cmdKey, layout: dvorak))
        let silent: (UInt32) -> String? = { _ in nil }
        #expect(reserved(kVK_Space, cmdKey, layout: silent))
        #expect(!reserved(kVK_ANSI_C, cmdKey, layout: silent), "an unnamed key is not known to be reserved")
    }

    /// A defaults suite of the test's own, never the reader's: the shortcut a test saves must not become theirs.
    static func scratchDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ai.xdict.tests.anywhere.\(UUID().uuidString)"))
    }
}

import AppKit
import Foundation
import Testing
import XDictTokens
@testable import XDictUI

/// **The answer pane's options** (owner, 2026-10-24): gap, width, opening time and toggle keys, each held within what
/// Settings offers however the stored value was written, and a combination XDict cannot take refused with its reason.
struct MeaningPanePreferencesTests {
    static func fresh() throws -> UserDefaults {
        let suite = "test.meaningPane.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func theDefaultsAreTheTokensAndTheAgreedOpening() throws {
        let defaults = try Self.fresh()
        #expect(MeaningPanePreferences.gap(defaults) == CGFloat(Tokens.Window.paneGap))
        #expect(MeaningPanePreferences.width(defaults) == CGFloat(Tokens.Window.meaningPaneIdeal))
        #expect(MeaningPanePreferences.animation(defaults) == 0.5)
        let shortcut = MeaningPanePreferences.shortcut(defaults)
        #expect(shortcut.key == "i" && shortcut.modifiers == .command)
        #expect(MeaningPanePreferences.shortcutLabel(key: "i", modifiers: .command) == "⌘I")
    }

    @Test func storedValuesAreHeldWithinTheirRanges() throws {
        let defaults = try Self.fresh()
        defaults.set(100.0, forKey: MeaningPanePreferences.gapKey)
        defaults.set(10.0, forKey: MeaningPanePreferences.widthKey)
        defaults.set(9.0, forKey: MeaningPanePreferences.animationKey)
        #expect(MeaningPanePreferences.gap(defaults) == CGFloat(MeaningPanePreferences.gapRange.upperBound))
        #expect(MeaningPanePreferences.width(defaults) == CGFloat(MeaningPanePreferences.widthRange.lowerBound))
        #expect(MeaningPanePreferences.animation(defaults) == MeaningPanePreferences.animationRange.upperBound)
    }

    /// **A non-finite preference is never geometry** (2026-10-24): NaN or infinity reads back as the default.
    @Test func nonFiniteValuesReadBackAsTheDefault() throws {
        let defaults = try Self.fresh()
        defaults.set(Double.nan, forKey: MeaningPanePreferences.gapKey)
        defaults.set(Double.infinity, forKey: MeaningPanePreferences.widthKey)
        defaults.set(-Double.infinity, forKey: MeaningPanePreferences.animationKey)
        #expect(MeaningPanePreferences.gap(defaults) == CGFloat(MeaningPanePreferences.defaultGap))
        #expect(MeaningPanePreferences.width(defaults) == CGFloat(MeaningPanePreferences.defaultWidth))
        #expect(MeaningPanePreferences.animation(defaults) == MeaningPanePreferences.defaultAnimation)
    }

    @Test func aRecordedShortcutIsReadBack() throws {
        let defaults = try Self.fresh()
        defaults.set("K", forKey: MeaningPanePreferences.shortcutKey)
        defaults.set(Int(NSEvent.ModifierFlags.command.union(.shift).rawValue),
                     forKey: MeaningPanePreferences.shortcutModifiersKey)
        let shortcut = MeaningPanePreferences.shortcut(defaults)
        #expect(shortcut.key == "k" && shortcut.modifiers == [.command, .shift])
        #expect(MeaningPanePreferences.shortcutLabel(key: "k", modifiers: shortcut.modifiers) == "⇧⌘K")
    }

    /// **The one decoder holds a malformed preference to the default** (2026-10-24): a negative integer would trap in
    /// `UInt(_:)`, and a key without ⌘, ⌃ or ⌥ would fire while typing.
    @Test func aMalformedShortcutReadsBackAsTheDefault() {
        let negative = MeaningPanePreferences.shortcut(key: "k", modifiersRaw: -1)
        #expect(negative.key == MeaningPanePreferences.defaultShortcutKey)
        #expect(negative.modifiers == .command)
        let bare = MeaningPanePreferences.shortcut(key: "k", modifiersRaw: 0)
        #expect(bare.key == MeaningPanePreferences.defaultShortcutKey)
        let shifted = MeaningPanePreferences.shortcut(key: "k",
                                                      modifiersRaw: Int(NSEvent.ModifierFlags.shift.rawValue))
        #expect(shifted.key == MeaningPanePreferences.defaultShortcutKey)
        let empty = MeaningPanePreferences.shortcut(key: "  ", modifiersRaw: Int(NSEvent.ModifierFlags.command.rawValue))
        #expect(empty.key == MeaningPanePreferences.defaultShortcutKey)
        // Incidental flags are dropped; the four that matter are kept.
        let mixedFlags: NSEvent.ModifierFlags = [.command, .capsLock, .numericPad]
        let mixed = MeaningPanePreferences.shortcut(key: "j", modifiersRaw: Int(mixedFlags.rawValue))
        #expect(mixed.key == "j" && mixed.modifiers == .command)
    }

    /// **What the pane refuses, and why** (2026-10-24): ⌘F is Find, ⇧A would fire while typing, ⌘I is the pane's own.
    @Test func aCombinationXDicAlreadyAnswersToIsRefused() {
        let find = MeaningPanePreferences.rejection(key: "f", modifiers: .command)
        #expect(find?.reason == .taken)
        #expect(find?.command?.isEmpty == false)
        #expect(MeaningPanePreferences.rejection(key: "f", modifiers: [.command, .option])?.reason == .taken)
        #expect(MeaningPanePreferences.rejection(key: "q", modifiers: .command)?.reason == .taken)
        // The File menu's: New Window ("New" in SwiftUI's own group), New Tab and Add Dictionaries….
        #expect(MeaningPanePreferences.rejection(key: "n", modifiers: .command)?.reason == .taken)
        #expect(MeaningPanePreferences.rejection(key: "t", modifiers: .command)?.reason == .taken)
        #expect(MeaningPanePreferences.rejection(key: "o", modifiers: .command)?.reason == .taken)
        // **Typed, not listed**: ⌘{ / ⌘} / ⌘+ arrive with the shift the character itself needs, and are the same chord.
        #expect(MeaningPanePreferences.rejection(key: "{", modifiers: [.command, .shift])?.reason == .taken)
        #expect(MeaningPanePreferences.rejection(key: "}", modifiers: [.command, .shift])?.reason == .taken)
        #expect(MeaningPanePreferences.rejection(key: "+", modifiers: [.command, .shift])?.reason == .taken)
        // A letter's shift is an extra modifier, so these stay the reader's.
        #expect(MeaningPanePreferences.rejection(key: "f", modifiers: [.command, .shift]) == nil)
        #expect(MeaningPanePreferences.rejection(key: "i", modifiers: .command) == nil)
    }

    @Test func aCombinationThatWouldFireWhileTypingIsRefused() {
        #expect(MeaningPanePreferences.rejection(key: "a", modifiers: [])?.reason == .needsCommand)
        #expect(MeaningPanePreferences.rejection(key: "a", modifiers: .shift)?.reason == .needsCommand)
        #expect(MeaningPanePreferences.rejection(key: "a", modifiers: .capsLock)?.reason == .needsCommand)
    }

    @Test func aKeyThatCannotBeAMenuShortcutIsRefused() {
        // What the recorder actually receives for keys that type nothing printable.
        #expect(MeaningPanePreferences.rejection(key: "\u{1B}", modifiers: .command)?.reason == .notAKey)
        #expect(MeaningPanePreferences.rejection(key: "\t", modifiers: .command)?.reason == .notAKey)
        #expect(MeaningPanePreferences.rejection(key: "", modifiers: .command)?.reason == .notAKey)
        #expect(MeaningPanePreferences.rejection(key: "ab", modifiers: .command)?.reason == .notAKey)
        // A layout's own letter is a key: XDict serves readers whose keyboards are not Latin.
        #expect(MeaningPanePreferences.rejection(key: "α", modifiers: .command) == nil)
    }

    /// Every refusal says something, and a taken one names the command.
    @Test func everyRefusalHasASentence() {
        let taken = MeaningPanePreferences.ShortcutRejection(reason: .taken, command: "Find")
        #expect(MeaningPanePreferences.sentence(taken).contains("Find"))
        for reason in [MeaningPanePreferences.ShortcutRejection.Reason.notAKey, .needsCommand] {
            let rejection = MeaningPanePreferences.ShortcutRejection(reason: reason, command: nil)
            #expect(!MeaningPanePreferences.sentence(rejection).isEmpty)
        }
    }
}

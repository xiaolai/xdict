import Foundation
import Testing
@testable import XDictSpeech

/// The reader's accent, kept across launches in the app's own defaults (`platform-architecture.md` §4a: en-US, en-GB).
struct SpeechPreferencesTests {
    static func defaults(_ name: String) -> UserDefaults {
        let suite = "ai.xdict.tests.speech.\(name).\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    @Test func theAccentIsAmericanUntilTheReaderChooses() {
        #expect(SpeechPreferences(defaults: Self.defaults("unset")).accent == .american)
    }

    @Test func aChosenAccentPersists() {
        let defaults = Self.defaults("chosen")
        SpeechPreferences(defaults: defaults).accent = .british
        #expect(SpeechPreferences(defaults: defaults).accent == .british)
        #expect(defaults.string(forKey: SpeechPreferences.accentKey) == "en-GB")
    }

    /// A value this version does not know reads as the default, never as a crash or an empty voice.
    @Test func anUnknownStoredAccentReadsAsTheDefault() {
        let defaults = Self.defaults("unknown")
        defaults.set("en-ZZ", forKey: SpeechPreferences.accentKey)
        #expect(SpeechPreferences(defaults: defaults).accent == .american)
    }

    @Test func theAccentsAreTheTwoTheArchitectureNames() {
        #expect(Accent.allCases.map(\.rawValue) == ["en-US", "en-GB"])
    }
}

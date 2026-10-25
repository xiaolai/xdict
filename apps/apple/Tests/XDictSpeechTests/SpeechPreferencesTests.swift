import Foundation
import Testing
import XDictTestSupport
@testable import XDictSpeech

/// The reader's accent, kept across launches in the app's own defaults (`platform-architecture.md` §4a: en-US, en-GB).
struct SpeechPreferencesTests {
    /// **The suite this test writes to**, held until the test's own instance goes (audit findings, 2026-10-25: a
    /// generated suite name that the system refused fell back to the reader's own defaults).
    let held = HeldDefaults()

    func defaults(_ name: String) throws -> UserDefaults {
        let fixture = try TestDefaults(prefix: "ai.xdict.tests.speech.\(name)")
        held.fixture = fixture
        return fixture.database
    }

    @Test func theAccentIsAmericanUntilTheReaderChooses() throws {
        #expect(SpeechPreferences(defaults: try defaults("unset")).accent == .american)
    }

    @Test func aChosenAccentPersists() throws {
        let defaults = try defaults("chosen")
        SpeechPreferences(defaults: defaults).accent = .british
        #expect(SpeechPreferences(defaults: defaults).accent == .british)
        #expect(defaults.string(forKey: SpeechPreferences.accentKey) == "en-GB")
    }

    /// A value this version does not know reads as the default, never as a crash or an empty voice.
    @Test func anUnknownStoredAccentReadsAsTheDefault() throws {
        let defaults = try defaults("unknown")
        defaults.set("en-ZZ", forKey: SpeechPreferences.accentKey)
        #expect(SpeechPreferences(defaults: defaults).accent == .american)
    }

    @Test func theAccentsAreTheTwoTheArchitectureNames() {
        #expect(Accent.allCases.map(\.rawValue) == ["en-US", "en-GB"])
    }
}

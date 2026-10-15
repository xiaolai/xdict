import Foundation
import Testing
@testable import XDictSpeech

/// **Which system voice speaks** (plan-macos-v1 WI-7; `platform-architecture.md` §4a): the dictionary's declared
/// language (WI-5's library), never inferred from the text, in the reader's accent where the language is English; the
/// best quality installed; never a novelty or a personal voice. Over constructed voices, so every arm runs on any Mac.
struct VoiceChoiceTests {
    static func voice(_ name: String, _ language: String, _ quality: VoiceQuality = .compact, novelty: Bool = false,
                      personal: Bool = false, languageDefault: Bool = false) -> VoiceInfo {
        VoiceInfo(identifier: "test.\(language).\(name)", name: name, language: language, quality: quality,
                  isNovelty: novelty, isPersonal: personal, isLanguageDefault: languageDefault)
    }

    static let installed = [
        voice("Albert", "en-US", novelty: true), voice("Fred", "en-US"), voice("Samantha", "en-US", languageDefault: true),
        voice("Daniel", "en-GB", languageDefault: true), voice("Kate", "en-GB"), voice("Karen", "en-AU"),
        voice("Tingting", "zh-CN", languageDefault: true), voice("Meijia", "zh-TW", languageDefault: true),
        voice("Sinji", "zh-HK", languageDefault: true), voice("Kyoko", "ja-JP", languageDefault: true),
    ]

    // MARK: - The language a dictionary is spoken in

    @Test func englishIsSpokenInTheReadersAccent() {
        #expect(SpeechLanguage.voiceTags(declared: "en", accent: .american) == ["en-US", "en"])
        #expect(SpeechLanguage.voiceTags(declared: "en", accent: .british) == ["en-GB", "en"])
    }

    /// A region the library holds is the reader's own word for the dictionary, and outranks the accent.
    @Test func aDeclaredRegionIsKept() {
        #expect(SpeechLanguage.voiceTags(declared: "en-AU", accent: .british) == ["en-AU", "en"])
    }

    /// The library holds Chinese by script; a voice is chosen by region. Mandarin before Cantonese for both scripts.
    @Test func chineseIsSpokenByAVoiceOfItsScriptsRegion() {
        #expect(SpeechLanguage.voiceTags(declared: "zh-Hans", accent: .british) == ["zh-CN", "zh-TW", "zh"])
        #expect(SpeechLanguage.voiceTags(declared: "zh-Hant", accent: .american) == ["zh-TW", "zh-HK", "zh-CN", "zh"])
        #expect(SpeechLanguage.voiceTags(declared: "zh", accent: .american) == ["zh-CN", "zh-TW", "zh"])
    }

    @Test func anotherLanguageIsSpokenAsDeclared() {
        #expect(SpeechLanguage.voiceTags(declared: "ja", accent: .british) == ["ja"])
        #expect(SpeechLanguage.voiceTags(declared: "fr", accent: .american) == ["fr"])
    }

    /// **Not inferred**: a dictionary with no declared language gets no guess from its text (R8).
    @Test func noDeclaredLanguageChoosesNothing() {
        #expect(SpeechLanguage.voiceTags(declared: nil, accent: .american) == nil)
        #expect(SpeechLanguage.voiceTags(declared: " ", accent: .american) == nil)
    }

    // MARK: - The voice

    @Test func theAccentChoosesTheVoice() {
        let american = Voices.best(for: ["en-US", "en"], among: Self.installed)
        let british = Voices.best(for: ["en-GB", "en"], among: Self.installed)
        #expect(american?.name == "Samantha")
        #expect(british?.name == "Daniel")
    }

    @Test func aDictionaryDeclaredChineseGetsAChineseVoice() {
        #expect(Voices.best(for: ["zh-CN", "zh-TW", "zh"], among: Self.installed)?.language == "zh-CN")
        let mandarinOnlyInTaiwan = Self.installed.filter { $0.language != "zh-CN" }
        #expect(Voices.best(for: ["zh-CN", "zh-TW", "zh"], among: mandarinOnlyInTaiwan)?.language == "zh-TW")
    }

    /// The better quality wins over the system's default for the language; the default breaks a tie.
    @Test func theBestQualityInstalledWinsAndTheDefaultBreaksATie() {
        let voices = Self.installed + [Self.voice("Ava", "en-US", .premium), Self.voice("Zoe", "en-US", .enhanced)]
        #expect(Voices.best(for: ["en-US"], among: voices)?.name == "Ava")
        #expect(Voices.best(for: ["en-US"], among: Self.installed)?.name == "Samantha")
    }

    /// A novelty voice is a joke at the reader's expense, and a personal voice is someone's own.
    @Test func neitherANoveltyNorAPersonalVoiceIsChosen() {
        let odd = [Self.voice("Albert", "en-US", .premium, novelty: true), Self.voice("Mine", "en-US", .premium, personal: true)]
        #expect(Voices.best(for: ["en-US"], among: odd) == nil)
        #expect(Voices.best(for: ["en-US"], among: odd + [Self.voice("Fred", "en-US")])?.name == "Fred")
    }

    /// Only the region asked for matches a regional tag; a bare tag matches every region.
    @Test func aRegionalTagIsExactAndABareOneMatchesEveryRegion() {
        #expect(Voices.best(for: ["en-NZ"], among: Self.installed) == nil)
        #expect(Voices.best(for: ["en-NZ", "en"], among: Self.installed)?.language.hasPrefix("en-") == true)
        #expect(Voices.best(for: ["ja"], among: Self.installed)?.name == "Kyoko")
        #expect(Voices.best(for: ["zz"], among: Self.installed) == nil)
    }

    /// The tag order is the preference: an earlier tag's compact voice outranks a later tag's premium one.
    @Test func anEarlierTagOutranksABetterVoiceOfALaterOne() {
        let voices = Self.installed + [Self.voice("Ava", "en-US", .premium)]
        #expect(Voices.best(for: ["en-GB", "en"], among: voices)?.name == "Daniel")
    }

    // MARK: - What the reader is told about the voice

    @Test func noVoiceIsACaveat() {
        #expect(Voices.caveat(for: ["zz"], among: Self.installed) == .noVoice)
    }

    @Test func aCompactVoiceSaysWhatIsBetter() {
        #expect(Voices.caveat(for: ["en-US", "en"], among: Self.installed) == .compactOnly(.get("Ava")))
        #expect(Voices.caveat(for: ["en-GB", "en"], among: Self.installed) == .compactOnly(.get("Serena")))
        #expect(Voices.caveat(for: ["zh-CN", "zh-TW", "zh"], among: Self.installed) == .compactOnly(.nothingBetter))
        #expect(Voices.caveat(for: ["ja"], among: Self.installed) == .compactOnly(.unknown))
    }

    @Test func aGoodVoiceIsNotApologisedFor() {
        let voices = Self.installed + [Self.voice("Zoe", "en-US", .enhanced)]
        #expect(Voices.caveat(for: ["en-US"], among: voices) == nil)
    }
}

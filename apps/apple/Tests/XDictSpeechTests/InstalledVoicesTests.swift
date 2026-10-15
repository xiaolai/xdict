import AVFAudio
import Foundation
import Testing
@testable import XDictSpeech

/// **The voices this Mac has**, read as the app reads them: moved from XiaolaiDict's `SpeechTests` with its `Speech`
/// (plan-macos-v1 WI-7, ADR-0001 decision 1), less its language inference (`Lemmatizer`, cut: XDict speaks a
/// dictionary's declared language, never a guess from the word). Nothing here speaks: voices are listed, never used.
@MainActor
struct InstalledVoicesTests {
    private let installed = Voices.installed

    @Test func theInstalledVoicesAreRead() throws {
        try #require(!installed.isEmpty, "this Mac lists no voice at all")
        #expect(installed.allSatisfy { !$0.identifier.isEmpty && !$0.language.isEmpty })
    }

    @Test func itPrefersTheBestQualityInstalled() throws {
        let english = installed.filter { $0.language.hasPrefix("en") && !$0.isNovelty && !$0.isPersonal }
        try #require(!english.isEmpty, "this Mac has no English voice at all")
        let chosen = try #require(Voices.best(for: ["en"], among: installed))
        #expect(chosen.quality == english.map(\.quality).max())
    }

    /// Measured on the build Mac, 2026-10-15: macOS lists 15 novelty voices (Albert, Bad News, Bells…) as en-US voices
    /// of the compact quality, beside Samantha. XiaolaiDict's first-of-the-quality could pick one; the traits say which
    /// they are. Asked among the compact voices that are no language's default, where nothing else would outrank one.
    @Test func theNoveltyVoicesAreKnownAndNeverChosen() throws {
        let novelty = installed.filter(\.isNovelty)
        try #require(!novelty.isEmpty, "this Mac lists no novelty voice, so the trait cannot be shown read")
        let plain = installed.filter { $0.quality == .compact && !$0.isLanguageDefault }
        for tag in Set(novelty.map(\.language)) {
            #expect(Voices.best(for: [tag], among: plain)?.isNovelty == false, "\(tag)")
        }
    }

    /// The system's own voice for a language is known, so it breaks a tie.
    @Test func eachLanguagesDefaultVoiceIsKnown() throws {
        let defaults = installed.filter(\.isLanguageDefault)
        try #require(!defaults.isEmpty)
        #expect(Set(defaults.map(\.language)).count == defaults.count, "two defaults for one language")
    }

    /// No voice is a fact to report, not a crash and not silence pretending to be speech.
    @Test func aLanguageWithNoVoiceIsReported() {
        #expect(Voices.best(for: ["zz"], among: installed) == nil)
        #expect(Voices.caveat(for: ["zz"], among: installed) == .noVoice)
    }

    /// **A voice downloaded while the app runs is used at once**: the list is kept because reading it costs 43 ms a
    /// call (measured in XiaolaiDict, 180 voices), and macOS posts `availableVoicesDidChangeNotification` when it
    /// changes. A count, not the cache's state, since tests run in parallel and another may warm it in between.
    @Test func aVoiceListChangeDropsTheKeptList() async {
        _ = Voices.installed
        #expect(Voices.cacheIsWarm, "the list was not kept, so this test proves nothing")
        let before = Voices.timesVoicesChanged
        NotificationCenter.default.post(name: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil)
        let deadline = Date().addingTimeInterval(2)
        while Voices.timesVoicesChanged == before, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(Voices.timesVoicesChanged > before, "a new voice would not be noticed until the next launch")
        #expect(!Voices.installed.isEmpty)
    }

    /// The recommendation is a claim about macOS, so it is made only where it was measured (XiaolaiDict, macOS 27,
    /// 2026-10-01: Ava installed and rendered; Serena in the catalogue; no Chinese voice above compact).
    @Test func onlyLanguagesWithAMeasuredAnswerAreRecommended() {
        #expect(Voices.advice(for: "en-US") == .get("Ava"))
        #expect(Voices.advice(for: "en") == .get("Ava"))
        #expect(Voices.advice(for: "en-GB") == .get("Serena"))
        #expect(Voices.advice(for: "zh-CN") == .nothingBetter)
        for unmeasured in ["ja-JP", "fr-FR", "de-DE", "en-AU", "en-IN"] {
            #expect(Voices.advice(for: unmeasured) == .unknown, "\(unmeasured) claimed to be measured")
        }
    }

    /// Where voices are installed on macOS 27, which is not System Settings (XiaolaiDict, checked 2026-10-01).
    @Test func theVoiceLibraryIsVoiceOverUtility() {
        #expect(Voices.voiceLibraryURL.lastPathComponent == "VoiceOver Utility.app")
        #expect(FileManager.default.fileExists(atPath: Voices.voiceLibraryURL.path))
    }
}

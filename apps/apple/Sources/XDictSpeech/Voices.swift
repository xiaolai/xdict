import AVFAudio
import Foundation

/// How good a system voice is, as macOS ranks them.
public enum VoiceQuality: Int, Comparable, Hashable, Sendable {
    case compact = 1, enhanced, premium

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    init(_ quality: AVSpeechSynthesisVoiceQuality) {
        switch quality {
        case .premium: self = .premium
        case .enhanced: self = .enhanced
        default: self = .compact
        }
    }
}

/// **One system voice, as a value**: what choosing one needs, so the choice is tested over any list, and nothing but
/// the output touches `AVSpeechSynthesisVoice`.
public struct VoiceInfo: Hashable, Sendable {
    public let identifier: String
    public let name: String
    /// BCP 47 as AVFoundation spells it: `en-US`, `zh-CN`.
    public let language: String
    public let quality: VoiceQuality
    /// Albert, Bad News, Bells… (`AVSpeechSynthesisVoice.Traits.isNoveltyVoice`): 15 on the build Mac, 2026-10-15.
    public let isNovelty: Bool
    /// A reader's own Personal Voice: never used to read a dictionary.
    public let isPersonal: Bool
    /// The voice macOS itself uses for this language (`AVSpeechSynthesisVoice(language:)`).
    public let isLanguageDefault: Bool

    public init(identifier: String, name: String, language: String, quality: VoiceQuality, isNovelty: Bool,
                isPersonal: Bool, isLanguageDefault: Bool) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
        self.isPersonal = isPersonal
        self.isLanguageDefault = isLanguageDefault
    }
}

/// What is known about better voices for a language. **Three cases, because there are three**: a voice worth naming, a
/// measured absence, and a language nobody has looked at (XiaolaiDict: collapsing the last two told most of the world
/// that macOS offers them nothing).
public enum VoiceAdvice: Hashable, Sendable {
    /// Measured: this voice installs and speaks.
    case get(String)
    /// Measured: macOS offers nothing above compact for this language.
    case nothingBetter
    /// Not measured. There may or may not be something.
    case unknown
}

/// What the reader can be told about the voice that would speak: nil when there is nothing worth saying.
public enum VoiceCaveat: Hashable, Sendable {
    /// No voice is installed for the language.
    case noVoice
    /// Only a compact voice is: noticeably worse, and a reader who does not know better ones exist concludes the app
    /// sounds bad.
    case compactOnly(VoiceAdvice)
}

/// **The system's voices, and which one speaks** (plan-macos-v1 WI-7). Moved from XiaolaiDict's `Speech` (ADR-0001
/// decision 1; its spike S1: a signed bundle lists every voice and synthesises with them, and the good ones are the
/// reader's to download), less its language inference: XDict speaks the dictionary's declared language
/// (`SpeechLanguage`), never a guess from the word. Re-checked for XDict: the first voice of a quality could be a
/// novelty voice (macOS lists Albert and Zarvox as English, compact), so those and personal voices are never chosen,
/// and the system's own voice for the language breaks a tie.
public enum Voices {
    // MARK: - Choosing

    /// The best voice for the first of `tags` any installed voice speaks: premium, then enhanced, then compact, the
    /// system's own voice for the language first among equals. A regional tag (`en-GB`) matches that region alone, a
    /// bare one (`en`) every region. Nil when none speaks any of them.
    public static func best(for tags: [String], among voices: [VoiceInfo]) -> VoiceInfo? {
        let usable = voices.filter { !$0.isNovelty && !$0.isPersonal }
        for tag in tags {
            let matching = usable.filter { speaks($0.language, tag) }
            if let best = matching.max(by: rankedBelow) { return best }
        }
        return nil
    }

    /// Whether a voice of `language` speaks `tag`.
    static func speaks(_ language: String, _ tag: String) -> Bool {
        let language = language.lowercased(), tag = tag.lowercased()
        return language == tag || (!tag.contains("-") && language.hasPrefix(tag + "-"))
    }

    /// Quality, then the language's own default, then the name backwards (so `max` picks the first alphabetically, for
    /// a choice that does not move between launches).
    private static func rankedBelow(_ lhs: VoiceInfo, _ rhs: VoiceInfo) -> Bool {
        if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
        if lhs.isLanguageDefault != rhs.isLanguageDefault { return !lhs.isLanguageDefault }
        return lhs.name > rhs.name
    }

    // MARK: - What the reader is told

    public static func caveat(for tags: [String], among voices: [VoiceInfo]) -> VoiceCaveat? {
        guard let voice = best(for: tags, among: voices) else { return .noVoice }
        return voice.quality == .compact ? .compactOnly(advice(for: voice.language)) : nil
    }

    /// What is known for `language`, and nothing beyond it. **Ava is the only entry backed by a run of the product**
    /// (XiaolaiDict, macOS 27 build 26A428, 2026-10-01, inside the signed bundle: installed from VoiceOver Utility,
    /// vended as premium, rendering 35,483 frames against the compact Samantha's 31,498). Serena is in the catalogue
    /// macOS 27 ships and has not been installed by either project. Chinese is the one measured absence: no variety is
    /// in the catalogue above compact. Everything else, other English regions included, is unknown.
    public static func advice(for language: String) -> VoiceAdvice {
        if language.hasPrefix("zh") { return .nothingBetter }
        if language.hasPrefix("en-GB") { return .get("Serena") }
        if language == "en" || language.hasPrefix("en-US") { return .get("Ava") }
        return .unknown
    }

    /// **Where a voice is chosen, previewed and downloaded on macOS 27**: System Settings ▸ Accessibility ▸ Read & Speak ▸
    /// System voice ▸ the ⓘ button (the owner, by hand, 2026-10-16). Corrected 2026-10-16: this note said VoiceOver
    /// Utility ▸ Speech, from XiaolaiDict's check of 2026-10-01, and that Settings had no voice list. There is no API to
    /// install one, so the app opens the pane. The anchor (`SpokenContent`) was not seen landing on Read & Speak (the
    /// second E2E Mac's screen showed no Settings window over SSH); without it the URL still opens Accessibility.
    public static let voiceSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")
        ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")

    // MARK: - The installed list

    /// `speechVoices()` costs 43 ms a call (XiaolaiDict, 180 voices), and a view asks from its body; so the list is kept,
    /// and dropped when macOS says it changed, so a voice downloaded while XDict runs is used at once.
    @MainActor private static var cached: [VoiceInfo]?
    @MainActor private static var watching = false
    @MainActor static private(set) var timesVoicesChanged = 0
    @MainActor static var cacheIsWarm: Bool { cached != nil }

    @MainActor public static var installed: [VoiceInfo] {
        // Before the early return: a cache warmed by any route must be watched.
        watchForNewVoices()
        if let cached { return cached }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        var defaults: [String: String] = [:]
        for language in Set(voices.map(\.language)) {
            defaults[language] = AVSpeechSynthesisVoice(language: language)?.identifier
        }
        let list = voices.map { voice in
            VoiceInfo(identifier: voice.identifier, name: voice.name, language: voice.language,
                      quality: VoiceQuality(voice.quality), isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
                      isPersonal: voice.voiceTraits.contains(.isPersonalVoice),
                      isLanguageDefault: defaults[voice.language] == voice.identifier)
        }
        cached = list
        return list
    }

    /// Registered once, from the first read, never removed: the list lives as long as the process. `queue: nil` and an
    /// explicit hop, since a test host has no main run loop to serve `OperationQueue.main` (XiaolaiDict).
    @MainActor private static func watchForNewVoices() {
        guard !watching else { return }
        watching = true
        // swiftlint:disable:next discarded_notification_center_observer
        NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                                               object: nil, queue: nil) { _ in
            Task { @MainActor in forgetInstalledVoices() }
        }
    }

    @MainActor static func forgetInstalledVoices() {
        cached = nil
        timesVoicesChanged += 1
    }
}

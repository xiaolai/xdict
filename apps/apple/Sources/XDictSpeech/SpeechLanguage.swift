import Foundation

/// The reader's accent for English (`platform-architecture.md` §4a: the system voice in the reader's choice of accent,
/// en-US or en-GB). Its raw value is the voice language it asks for.
public enum Accent: String, CaseIterable, Hashable, Sendable {
    case american = "en-US"
    case british = "en-GB"
}

/// **The language a dictionary is spoken in: the one it is declared in** (plan-macos-v1 WI-7, R8), never inferred from
/// the text. The library holds each dictionary's search language as the reader confirmed or the file name stated it
/// (WI-5, L3: `en`, `zh-Hans`, `ja`…); a voice is chosen by region, so this turns one into the other, most wanted first.
public enum SpeechLanguage {
    /// The voice languages to try for a dictionary declared `declared`, in `accent` where it is English. Nil when the
    /// dictionary declares no language: the reader is asked to set one, and nothing is guessed.
    public static func voiceTags(declared: String?, accent: Accent) -> [String]? {
        guard let declared = declared?.trimmingCharacters(in: .whitespaces), !declared.isEmpty else { return nil }
        let parts = declared.split(separator: "-").map(String.init)
        let base = parts.first?.lowercased() ?? declared
        switch base {
        case "en":
            // A region the reader gave outranks the accent; a bare `en` takes the accent.
            return parts.count > 1 ? [declared, "en"] : [accent.rawValue, "en"]
        case "zh":
            // By script: Simplified is Mandarin as spoken in mainland China; Traditional is Taiwan's Mandarin, then
            // Hong Kong's Cantonese. Any Chinese voice last, rather than none.
            if parts.dropFirst().contains(where: { $0.caseInsensitiveCompare("Hant") == .orderedSame }) {
                return ["zh-TW", "zh-HK", "zh-CN", "zh"]
            }
            return ["zh-CN", "zh-TW", "zh"]
        default:
            return [declared]
        }
    }
}

/// **The reader's speech choices, kept across launches** in the app's own defaults: the accent. What is read back is
/// held to what the app knows: a value it does not know reads as the default.
public struct SpeechPreferences: @unchecked Sendable {
    // `UserDefaults` is documented thread-safe; it is not marked `Sendable`.
    private let defaults: UserDefaults

    /// The defaults key, for the settings view's binding.
    public static let accentKey = "speech.accent"
    public static let defaultAccent = Accent.american

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static let useRecordingsKey = "speech.useRecordings"
    static let voiceTipKey = "speech.voiceTipShown"

    /// "Use the dictionary's recordings" (ADR-0010 Q5): off, the system voice speaks every sound link.
    public var useRecordings: Bool {
        get { defaults.bool(forKey: Self.useRecordingsKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.useRecordingsKey) }
    }

    /// The one-time tip that a better voice can be downloaded has been shown.
    public var voiceTipShown: Bool {
        get { defaults.bool(forKey: Self.voiceTipKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.voiceTipKey) }
    }

    public var accent: Accent {
        get { defaults.string(forKey: Self.accentKey).flatMap(Accent.init(rawValue:)) ?? Self.defaultAccent }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.accentKey) }
    }
}

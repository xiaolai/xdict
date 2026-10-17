import Foundation
import XDictLibrary
import XDictSearch
import XDictSpeech

/// **What a sound tells the reader, in their language** (plan-macos-v1 WI-7; R8, R9, L6): the pronunciation hands kinds,
/// these word them. A recording that plays is labelled as the dictionary's; one that cannot says why (the library's own
/// L6 sentences for missing and unsupported, WI-5), then what the system voice did instead, naming the voice; the voice
/// is never passed off as a recording. Every sentence is in `Strings/Localizable.xcstrings`, in English and Simplified
/// Chinese.
public enum SpeechSentences {
    /// A notice's lines: what happened to the recording, then, if it could not play, what the voice did instead.
    public static func lines(_ notice: PronunciationNotice) -> [LocalizedStringResource] {
        switch notice {
        case .recording:
            [LocalizedStringResource("Playing the dictionary's own recording.")]
        case .speech(let outcome):
            [speech(outcome)]
        case .fallback(let problem, let outcome):
            [recording(problem), instead(outcome)]
        }
    }

    /// Why a recording did not play: each reason its own sentence.
    static func recording(_ problem: RecordingProblem) -> LocalizedStringResource {
        switch problem {
        case .unsupported(let format):
            LibrarySentences.sound(.unsupported(format: format))
        case .missing(let path):
            LibrarySentences.sound(.missing(path: fileName(path)))
        case .undecodable(let format):
            LocalizedStringResource("This recording (\(format)) could not be opened: it may be damaged.")
        case .notStarted(let format):
            LocalizedStringResource("The sound output did not start, so this recording (\(format)) could not be played.")
        case .unavailable:
            LocalizedStringResource("The dictionary service did not deliver this recording.")
        }
    }

    /// The system voice, asked for directly.
    static func speech(_ outcome: SpeechOutcome) -> LocalizedStringResource {
        switch outcome {
        case .spoken(let voice, let language):
            LocalizedStringResource("Spoken by the system voice \(voice) (\(languageName(language))).")
        case .noLanguage:
            LocalizedStringResource("""
                This dictionary's language is not set, so XDict cannot choose a voice for it. Set it in the Library.
                """)
        case .noVoice(let language):
            LocalizedStringResource("""
                No system voice for \(languageName(language)) is installed. Voices are added in System Settings ▸ Accessibility ▸ Read & Speak ▸ System voice ▸ ⓘ.
                """)
        case .nothingToSay:
            LocalizedStringResource("There is nothing to say.")
        }
    }

    /// The system voice, in a recording's place.
    static func instead(_ outcome: SpeechOutcome) -> LocalizedStringResource {
        guard case .spoken(let voice, let language) = outcome else { return speech(outcome) }
        return LocalizedStringResource("Spoken by the system voice \(voice) (\(languageName(language))) instead.")
    }

    /// What is worth saying about the voice that would speak (moved from XiaolaiDict's `Speech.caveat`, worded here).
    public static func caveat(_ caveat: VoiceCaveat) -> LocalizedStringResource {
        switch caveat {
        case .noVoice:
            LocalizedStringResource("No voice is installed for this language.")
        case .compactOnly(.get(let better)):
            LocalizedStringResource("Only a compact voice is installed. \(better) is a free download in System Settings ▸ Accessibility ▸ Read & Speak ▸ System voice ▸ ⓘ.")
        case .compactOnly(.nothingBetter):
            LocalizedStringResource("Only a compact voice is available for this language. macOS offers nothing better for it.")
        case .compactOnly(.unknown):
            LocalizedStringResource("Only a compact voice is installed. Better ones may be available in System Settings ▸ Accessibility ▸ Read & Speak ▸ System voice ▸ ⓘ.")
        }
    }

    /// The speak button's help: the word as written, by the system voice, and no claim to a sense's pronunciation (R8).
    public static func speakHelp(word: String) -> LocalizedStringResource {
        LocalizedStringResource("Say “\(word)” as written, with the system voice")
    }

    public static func accent(_ accent: Accent) -> LocalizedStringResource {
        switch accent {
        case .american: LocalizedStringResource("American English")
        case .british: LocalizedStringResource("British English")
        }
    }

    /// A language's name as the reader's system writes it (`en-GB` → "English (United Kingdom)", in their language).
    static func languageName(_ tag: String) -> String {
        Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    /// A recording's file name as the reader is shown it: its last part, decoded, and cut in the middle when long (an
    /// OED path runs to some 200 characters).
    public static func fileName(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        let name = last.removingPercentEncoding ?? last
        guard name.count > 48 else { return name }
        return String(name.prefix(23)) + "…" + String(name.suffix(24))
    }
}

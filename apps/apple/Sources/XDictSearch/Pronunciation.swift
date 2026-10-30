import Foundation
import Observation
import XDictContract
import XDictLibrary
import XDictSpeech

/// What the system voice did with a text.
public enum SpeechOutcome: Hashable, Sendable {
    /// Spoken by this voice, of this language.
    case spoken(voice: String, language: String)
    /// The dictionary declares no language, so no voice is chosen: the reader is asked to set one (never inferred, R8).
    case noLanguage
    /// No voice speaks the dictionary's declared language.
    case noVoice(language: String)
    /// Nothing but space to say.
    case nothingToSay
}

/// Why a dictionary's recording did not play (R9, L6): each its own kind, so the reader is told which.
public enum RecordingProblem: Hashable, Sendable {
    /// A format macOS does not play (Speex above all): never handed to the player.
    case unsupported(format: String)
    /// Not among the dictionary's files.
    case missing(path: String)
    /// Named as a format macOS plays, and macOS could not open it.
    case undecodable(format: String)
    /// macOS opened it, and its sound output would not start (no output device, or the system refused).
    case notStarted(format: String)
    /// The dictionary service did not deliver it.
    case unavailable
}

/// **What the reader is told about a sound**: kinds, never sentences (the view layer words them).
public enum PronunciationNotice: Hashable, Sendable {
    /// The dictionary's own recording plays, labelled as the dictionary's.
    case recording(format: String)
    /// The system voice, asked for directly: a `.tts` link, or the speak button.
    case speech(SpeechOutcome)
    /// The recording could not play, and what the system voice did in its place.
    case fallback(RecordingProblem, SpeechOutcome)
}

/// What the pronunciation did, for whoever listens (the E2E instruments): each notice, and each thing the output did.
public enum PronunciationEvent: Hashable, Sendable {
    case notice(PronunciationNotice)
    case output(OutputEvent)
}

/// **A dictionary's sounds and the system voice, for one main window** (plan-macos-v1 WI-7; R8, R9, L6;
/// `platform-architecture.md` §4a).
///
/// - A `sound://` link's recording is fetched from the dictionary whose entry holds it, through the service, and played
///   by macOS when its format is one macOS plays (`SoundDiagnosis`, WI-5): mp3, WAV, Ogg Vorbis. Otherwise — Speex, which
///   nothing is added to play; a recording the dictionary lacks; one macOS cannot open, or cannot start sounding; one
///   the service does not deliver — the entry's word is spoken by the system voice, and the notice says which it was.
/// - A `.tts` link and the speak button speak in **the dictionary's declared language** (the library's, WI-5), in the
///   reader's accent where it is English; never a language guessed from the text. The text is spoken as written: no IPA
///   adapter is verified for any dictionary yet, so no sense-specific pronunciation is claimed (R8).
/// - One sound at a time: a request stops whatever sounds, and an older request's late answer is never played.
@MainActor
@Observable
public final class Pronunciation {
    /// A notice, and which request it answers: the same notice twice is shown twice.
    public struct Shown: Hashable, Sendable {
        public let notice: PronunciationNotice
        public let serial: Int
        /// The one-time tip that the voice that spoke is a compact one and a better one can be downloaded.
        public var tip: VoiceCaveat?
    }

    public private(set) var shown: Shown?
    @ObservationIgnored public var onEvent: (@MainActor (PronunciationEvent) -> Void)?

    @ObservationIgnored private let backend: any SearchBackend
    @ObservationIgnored private let output: any PronunciationOutput
    @ObservationIgnored private let preferences: SpeechPreferences
    @ObservationIgnored private let voices: @MainActor () -> [VoiceInfo]
    /// The latest request: an answer to an earlier one arrives to find it has moved on.
    @ObservationIgnored private var request = 0
    @ObservationIgnored private var serial = 0
    /// The tip the next notice carries, set when a compact voice speaks for the first time.
    @ObservationIgnored private var pendingTip: VoiceCaveat?

    public init(backend: any SearchBackend, output: any PronunciationOutput, preferences: SpeechPreferences,
                voices: @escaping @MainActor () -> [VoiceInfo] = { Voices.installed }) {
        self.backend = backend
        self.output = output
        self.preferences = preferences
        self.voices = voices
        output.onEvent = { [weak self] event in self?.onEvent?(.output(event)) }
    }

    /// A recording a `sound://` link names, `path` as the core gave it, from the dictionary open as `handle`; `word` is
    /// spoken in `language` if it cannot play.
    /// Unless the reader turned on "Use the dictionary's recordings", `word` is spoken by the system voice and nothing is
    /// fetched (ADR-0010 Q5).
    public func playRecording(_ path: String, from handle: DictId, word: String, language: String?) async {
        guard preferences.useRecordings else {
            speak(word, language: language)
            return
        }
        let mine = begin()
        let outcome = await backend.request(.resource(dict: handle, path: path, render: .reader))
        guard mine == request else { return }
        let problem: RecordingProblem
        switch outcome {
        case .success(let delivered):
            guard case .resource(let resource) = delivered.answer else {
                problem = .unavailable
                break
            }
            switch SoundDiagnosis.of(resource) {
            case .playable:
                guard let bytes = delivered.payload else {
                    problem = .unavailable
                    break
                }
                let format = Self.format(of: path)
                do {
                    _ = try output.play(bytes, format: format)
                    notify(.recording(format: format))
                    return
                } catch RecordingError.didNotStart {
                    problem = .notStarted(format: format)
                } catch {
                    problem = .undecodable(format: format)
                }
            case .unsupported(let format):
                problem = .unsupported(format: format)
            case .missing(let missing):
                problem = .missing(path: missing)
            }
        case .failure:
            problem = .unavailable
        }
        notify(.fallback(problem, say(word, language: language)))
    }

    /// Text to say in the dictionary's declared `language`: a `.tts` link, or the speak button's word.
    public func speak(_ text: String, language: String?) {
        _ = begin()
        notify(.speech(say(text, language: language)))
    }

    /// The voice that would speak `language` now: for the speak button's help and the settings.
    public func voice(for language: String?) -> VoiceInfo? {
        tags(language).flatMap { chosenVoice(for: $0) }
    }

    /// **The reader's chosen voice where it still speaks the language, else the best installed** (owner's settings audit,
    /// 2026-10-30): the choice is a voice identifier, and one that no longer speaks — the accent changed, the voice was
    /// removed from macOS — falls back instead of failing.
    private func chosenVoice(for tags: [String]) -> VoiceInfo? {
        let all = voices()
        if let identifier = preferences.voiceIdentifier,
           let chosen = all.first(where: { $0.identifier == identifier }),
           tags.contains(where: { Voices.speaks(chosen.language, $0) }) {
            return chosen
        }
        return Voices.best(for: tags, among: all)
    }

    /// What is worth saying about that voice, if anything; nil when no language is declared.
    public func caveat(for language: String?) -> VoiceCaveat? {
        tags(language).flatMap { Voices.caveat(for: $0, among: voices()) }
    }

    // MARK: -

    /// A new request: whatever sounds stops, and every earlier request is moved past.
    private func begin() -> Int {
        request += 1
        output.stop()
        return request
    }

    private func tags(_ language: String?) -> [String]? {
        SpeechLanguage.voiceTags(declared: language, accent: preferences.accent)
    }

    private func say(_ text: String, language: String?) -> SpeechOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .nothingToSay }
        guard let tags = tags(language), let language else { return .noLanguage }
        guard let voice = chosenVoice(for: tags), output.speak(text, with: voice) else {
            return .noVoice(language: language)
        }
        // The one-time tip: a compact voice spoke, and a better one may be a download away (not for a language macOS
        // has nothing better for, where it would be noise).
        let advice = Voices.advice(for: voice.language)
        if !preferences.voiceTipShown, voice.quality == .compact, advice != .nothingBetter {
            preferences.voiceTipShown = true
            pendingTip = .compactOnly(advice)
        }
        return .spoken(voice: voice.name, language: voice.language)
    }

    private func notify(_ notice: PronunciationNotice) {
        serial += 1
        shown = Shown(notice: notice, serial: serial, tip: pendingTip)
        pendingTip = nil
        onEvent?(.notice(notice))
    }

    /// A recording's format, as its name gives it: the extension, lower-cased.
    static func format(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}

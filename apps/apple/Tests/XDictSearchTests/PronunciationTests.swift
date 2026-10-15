import Foundation
import Testing
import XDictClient
import XDictContract
import XDictSearch
import XDictSpeech

/// **Where sound leaves the app, faked**: what was played and spoken, and every stop. No sound is made.
@MainActor
final class FakeOutput: PronunciationOutput {
    var onEvent: (@MainActor (OutputEvent) -> Void)?
    private(set) var played: [Data] = []
    private(set) var formats: [String] = []
    private(set) var spoken: [(text: String, voice: VoiceInfo)] = []
    private(set) var stops = 0
    var refuse: RecordingError?
    var voicesUnavailable = false

    func play(_ data: Data, format: String) throws -> Playback {
        if let refuse { throw refuse }
        played.append(data)
        formats.append(format)
        let playback = Playback(duration: 1.2, isPlaying: true, format: ".mp3")
        onEvent?(.playbackStarted(playback))
        return playback
    }

    func speak(_ text: String, with voice: VoiceInfo) -> Bool {
        guard !voicesUnavailable else { return false }
        spoken.append((text, voice))
        return true
    }

    func stop() { stops += 1 }
}

/// A service whose resources answer only when the test says: so a newer request can overtake an older one.
actor HeldResources: SearchBackend {
    private var waiting: [String: CheckedContinuation<ClientOutcome, Never>] = [:]
    private(set) var asked: [String] = []

    func queue(_ operations: [ServiceOperation], as caller: Caller, superseding: Bool) -> [PendingCall] { [] }
    func supersede(_ caller: Caller) {}

    func request(_ operation: ServiceOperation) async -> ClientOutcome {
        guard case .resource(_, let path, _) = operation else { return .failure(.wire(.interrupted)) }
        asked.append(path)
        return await withCheckedContinuation { waiting[path] = $0 }
    }

    func answer(_ path: String, _ outcome: ClientOutcome) -> Bool {
        guard let continuation = waiting.removeValue(forKey: path) else { return false }
        continuation.resume(returning: outcome)
        return true
    }
}

/// **A dictionary's sounds and the system voice, in the main window** (plan-macos-v1 WI-7; R8, R9, L6): a `sound://`
/// link's recording is fetched from the dictionary it is in and played, labelled as the dictionary's; one macOS cannot
/// play (Speex), one the dictionary lacks, one that will not decode and one the service does not deliver each fall back
/// to the system voice and say which it was; a `.tts` link and the speak button speak in the dictionary's declared
/// language, in the reader's accent; nothing is guessed when no language is declared.
@MainActor
struct PronunciationTests {
    static let voices = [
        VoiceInfo(identifier: "us.samantha", name: "Samantha", language: "en-US", quality: .compact, isNovelty: false,
                  isPersonal: false, isLanguageDefault: true),
        VoiceInfo(identifier: "gb.daniel", name: "Daniel", language: "en-GB", quality: .compact, isNovelty: false,
                  isPersonal: false, isLanguageDefault: true),
        VoiceInfo(identifier: "cn.tingting", name: "Tingting", language: "zh-CN", quality: .compact, isNovelty: false,
                  isPersonal: false, isLanguageDefault: true),
    ]
    nonisolated static let handle = DictId(rawValue: "handle-oald")
    nonisolated static let bytes = Data("a recording".utf8)

    let output = FakeOutput()
    let preferences = SpeechPreferences(defaults: UserDefaults(suiteName: "ai.xdict.tests.pronunciation.\(UUID())")
                                            ?? .standard)

    func pronunciation(_ backend: any SearchBackend) -> Pronunciation {
        Pronunciation(backend: backend, output: output, preferences: preferences, voices: { Self.voices })
    }

    static func backend(_ answer: @escaping @Sendable (ServiceOperation) -> ClientOutcome) async -> FakeSearchBackend {
        let backend = FakeSearchBackend { _, _, _ in .failure(.wire(.interrupted)) }
        await backend.setAnswer(answer)
        return backend
    }

    /// True once `condition` holds; false after two seconds, so a request never made fails rather than hangs.
    static func within(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while await !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    nonisolated static func found(_ path: String, _ mime: String) -> ClientOutcome {
        .success(Delivered(answer: .resource(.found(path: path, mime: mime)), payload: bytes))
    }

    // MARK: - Recordings

    @Test func aRecordingMacOSPlaysIsFetchedFromItsDictionaryPlayedAndLabelledAsTheDictionarys() async {
        let backend = await Self.backend { _ in Self.found("us/run.mp3", "audio/mpeg") }
        let speech = pronunciation(backend)
        await speech.playRecording("us/run.mp3", from: Self.handle, word: "run", language: "en")
        #expect(await backend.requests == [.resource(dict: Self.handle, path: "us/run.mp3", render: .reader)])
        #expect(output.played == [Self.bytes])
        #expect(output.spoken.isEmpty)
        #expect(speech.shown?.notice == .recording(format: "mp3"))
    }

    /// R9: Speex is never tried (`platform-architecture.md` §4a: nothing is added to play it); the word is spoken by
    /// the system voice, and the reader is told why.
    @Test func speexFallsBackToTheSystemVoiceAndSaysSo() async {
        let backend = await Self.backend { _ in Self.found("acrimonious.spx", "application/octet-stream") }
        let speech = pronunciation(backend)
        await speech.playRecording("acrimonious.spx", from: Self.handle, word: "acrimonious", language: "en")
        #expect(output.played.isEmpty, "Speex was handed to the player")
        #expect(output.spoken.map(\.text) == ["acrimonious"])
        #expect(speech.shown?.notice == .fallback(.unsupported(format: "spx"), .spoken(voice: "Samantha", language: "en-US")))
    }

    /// L6: missing and unsupported told apart.
    @Test func aMissingRecordingIsToldApartFromAnUnsupportedOne() async {
        let backend = await Self.backend { _ in .success(Delivered(answer: .resource(.missing(path: "gone.mp3")), payload: nil)) }
        let speech = pronunciation(backend)
        await speech.playRecording("gone.mp3", from: Self.handle, word: "gone", language: "en")
        #expect(output.played.isEmpty)
        #expect(output.spoken.map(\.text) == ["gone"])
        #expect(speech.shown?.notice == .fallback(.missing(path: "gone.mp3"), .spoken(voice: "Samantha", language: "en-US")))
    }

    /// A recording whose name says mp3 and whose bytes macOS cannot open: neither missing nor unsupported.
    @Test func aRecordingMacOSCannotOpenFallsBackAsUndecodable() async {
        let backend = await Self.backend { _ in Self.found("here.mp3", "audio/mpeg") }
        output.refuse = .undecodable(status: 1_685_348_671)
        let speech = pronunciation(backend)
        await speech.playRecording("here.mp3", from: Self.handle, word: "here", language: "en")
        #expect(output.spoken.map(\.text) == ["here"])
        #expect(speech.shown?.notice == .fallback(.undecodable(format: "mp3"), .spoken(voice: "Samantha", language: "en-US")))
    }

    /// A recording macOS decoded that the sound output would not start is not a damaged recording: it is told apart
    /// (this is how every OALD recording first failed, under a player that cannot play Ogg Vorbis).
    @Test func anOutputThatDoesNotStartIsToldApartFromAnUndecodableRecording() async {
        let backend = await Self.backend { _ in Self.found("007__gb_1.ogg", "audio/ogg") }
        output.refuse = .didNotStart
        let speech = pronunciation(backend)
        await speech.playRecording("007__gb_1.ogg", from: Self.handle, word: "007", language: "en")
        #expect(speech.shown?.notice == .fallback(.notStarted(format: "ogg"), .spoken(voice: "Samantha", language: "en-US")))
    }

    /// The output is told the recording's format as its name gives it: a hint for the decoder, never the verdict.
    @Test func theOutputIsToldTheNamedFormat() async {
        let backend = await Self.backend { _ in Self.found("x/007__gb_1.OGG", "audio/ogg") }
        await pronunciation(backend).playRecording("x/007__gb_1.OGG", from: Self.handle, word: "007", language: "en")
        #expect(output.formats == ["ogg"])
    }

    @Test func aRecordingTheServiceDoesNotDeliverFallsBack() async {
        let backend = await Self.backend { _ in .failure(.wire(.interrupted)) }
        let speech = pronunciation(backend)
        await speech.playRecording("run.mp3", from: Self.handle, word: "run", language: "en")
        #expect(speech.shown?.notice == .fallback(.unavailable, .spoken(voice: "Samantha", language: "en-US")))
    }

    /// The reader clicked another sound before the first arrived: the first is never played after it, and whatever
    /// sounded stops when the newer is asked for.
    @Test func aNewerRequestStopsTheEarlierAndAnOlderAnswerNeverPlays() async throws {
        let backend = HeldResources()
        let speech = pronunciation(backend)
        let first = Task { await speech.playRecording("uk.mp3", from: Self.handle, word: "run", language: "en") }
        try #require(await Self.within { await backend.asked == ["uk.mp3"] }, "the first recording was never asked for")
        let stopsBefore = output.stops
        let second = Task { await speech.playRecording("us.mp3", from: Self.handle, word: "run", language: "en") }
        try #require(await Self.within { await backend.asked == ["uk.mp3", "us.mp3"] }, "the second was never asked for")
        #expect(output.stops > stopsBefore, "the earlier sound was not stopped when the newer was asked for")
        #expect(await backend.answer("us.mp3", Self.found("us.mp3", "audio/mpeg")))
        await second.value
        #expect(await backend.answer("uk.mp3", Self.found("uk.mp3", "audio/mpeg")))
        await first.value
        #expect(output.played.count == 1, "the older recording played after the newer")
        #expect(speech.shown?.notice == .recording(format: "mp3"))
    }

    // MARK: - The system voice

    /// A `.tts` link and the speak button: the dictionary's declared language, in the reader's accent; switching the
    /// accent switches the voice.
    @Test func speechTakesTheDeclaredLanguageInTheReadersAccent() async {
        let speech = pronunciation(await Self.backend { _ in .failure(.wire(.interrupted)) })
        speech.speak("hello world", language: "en")
        preferences.accent = .british
        speech.speak("hello world", language: "en")
        #expect(output.spoken.map(\.voice.identifier) == ["us.samantha", "gb.daniel"])
        #expect(speech.shown?.notice == .speech(.spoken(voice: "Daniel", language: "en-GB")))
    }

    @Test func aDictionaryDeclaredChineseSpeaksWithAChineseVoice() async {
        let speech = pronunciation(await Self.backend { _ in .failure(.wire(.interrupted)) })
        speech.speak("你好", language: "zh-Hans")
        #expect(output.spoken.map(\.voice.language) == ["zh-CN"])
    }

    /// Not inferred (R8): with no declared language nothing is spoken, and the reader is told what to set.
    @Test func noDeclaredLanguageSpeaksNothingAndSaysSo() async {
        let speech = pronunciation(await Self.backend { _ in .failure(.wire(.interrupted)) })
        speech.speak("hello", language: nil)
        #expect(output.spoken.isEmpty)
        #expect(speech.shown?.notice == .speech(.noLanguage))
    }

    @Test func aLanguageWithNoVoiceIsNamed() async {
        let speech = pronunciation(await Self.backend { _ in .failure(.wire(.interrupted)) })
        speech.speak("안녕", language: "ko")
        #expect(speech.shown?.notice == .speech(.noVoice(language: "ko")))
        output.voicesUnavailable = true
        speech.speak("hello", language: "en")
        #expect(speech.shown?.notice == .speech(.noVoice(language: "en")))
        #expect(output.spoken.isEmpty)
    }

    @Test func nothingToSayIsSaidOnce() async {
        let speech = pronunciation(await Self.backend { _ in .failure(.wire(.interrupted)) })
        speech.speak("  \n", language: "en")
        #expect(output.spoken.isEmpty)
        #expect(speech.shown?.notice == .speech(.nothingToSay))
    }

    /// Every request is told, even the same notice twice: a reader who clicks again sees it again.
    @Test func eachRequestIsNoticedAgain() async {
        let speech = pronunciation(await Self.backend { _ in .failure(.wire(.interrupted)) })
        speech.speak("run", language: "en")
        let first = speech.shown
        speech.speak("run", language: "en")
        #expect(speech.shown?.notice == first?.notice)
        #expect(speech.shown?.serial != first?.serial)
    }

    /// What the output did reaches whoever listens: the E2E stage reads playback and speech from the app's own state.
    @Test func theOutputsEventsAndTheNoticesAreHeard() async {
        let backend = await Self.backend { _ in Self.found("run.mp3", "audio/mpeg") }
        let speech = pronunciation(backend)
        var heard: [PronunciationEvent] = []
        speech.onEvent = { heard.append($0) }
        await speech.playRecording("run.mp3", from: Self.handle, word: "run", language: "en")
        #expect(heard.contains(.output(.playbackStarted(Playback(duration: 1.2, isPlaying: true, format: ".mp3")))))
        #expect(heard.contains(.notice(.recording(format: "mp3"))))
    }

    /// The voice the speak button's help names, and its caveat, are the ones that would speak.
    @Test func theVoiceThatWouldSpeakIsKnownBeforeSpeaking() async {
        let speech = pronunciation(await Self.backend { _ in .failure(.wire(.interrupted)) })
        #expect(speech.voice(for: "en")?.name == "Samantha")
        #expect(speech.caveat(for: "en") == .compactOnly(.get("Ava")))
        #expect(speech.voice(for: nil) == nil)
    }
}

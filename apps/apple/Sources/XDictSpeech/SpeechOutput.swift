import AVFAudio
import Foundation
import XDictBase
import os

/// A recording as it started: how long it is, whether it was playing once started, and the format macOS read.
public struct Playback: Hashable, Sendable {
    public let duration: Double
    public let isPlaying: Bool
    /// The decoder's own name for what it read (`.mp3`, `vorb`, `lpcm`…), for the record.
    public let format: String

    public init(duration: Double, isPlaying: Bool, format: String) {
        self.duration = duration
        self.isPlaying = isPlaying
        self.format = format
    }
}

/// What a voice was asked to say, and with which voice.
public struct Utterance: Hashable, Sendable {
    public let text: String
    public let voiceIdentifier: String
    public let voiceName: String
    public let language: String

    public init(text: String, voiceIdentifier: String, voiceName: String, language: String) {
        self.text = text
        self.voiceIdentifier = voiceIdentifier
        self.voiceName = voiceName
        self.language = language
    }
}

/// **What the output did, as it did it**: a recording started and ended, an utterance started and ended. Nothing about a
/// sound is taken on trust: a recording that never starts and a voice that never calls back look exactly like success
/// from the caller (XiaolaiDict's S1 found a voice that resolved and rendered zero frames).
public enum OutputEvent: Hashable, Sendable {
    case playbackStarted(Playback)
    /// `finished`: played to its end. False when stopped, replaced or broken off by a decoding error.
    case playbackEnded(finished: Bool)
    case speechStarted(Utterance)
    /// `finished`: spoken to its end. False when stopped or replaced.
    case speechEnded(Utterance, finished: Bool)
}

/// Why a recording did not start.
public enum RecordingError: Error, Hashable, Sendable {
    /// macOS could not open the bytes as audio (the decoder refused them), with its status.
    case undecodable(status: Int)
    /// It decoded, and the sound output would not start (no output device, or the system refused).
    case didNotStart
}

/// A recording opened by the system's decoder, not yet playing.
struct OpenedRecording {
    let file: AVAudioFile
    var duration: Double { Double(file.length) / file.processingFormat.sampleRate }
    /// The decoder's name for the file's own format (`.mp3`, `vorb`, `lpcm`…), for the record.
    var format: String { SystemOutput.formatName(file.fileFormat) }
}

/// **Where sound leaves the app**: a recording played, a text spoken, everything stopped. One at a time: starting one
/// stops whatever was sounding. The seam the window's pronunciation speaks through, so its decisions are tested with
/// a fake that makes no sound.
@MainActor
public protocol PronunciationOutput: AnyObject {
    var onEvent: (@MainActor (OutputEvent) -> Void)? { get set }
    /// Decodes `data` (`format`, its name's extension, only a hint) and starts it. Throws `RecordingError`:
    /// `undecodable` if macOS cannot open it, having stopped nothing; `didNotStart` if the output would not start.
    func play(_ data: Data, format: String) throws -> Playback
    /// Speaks `text` with `voice`; false if the voice is not available, having stopped nothing.
    func speak(_ text: String, with voice: VoiceInfo) -> Bool
    func stop()
}

/// **The system's own output** (`platform-architecture.md` §4a): the dictionary's recordings decoded by the system's
/// own converters (`AVAudioFile`, ExtAudioFile: mp3, WAV, Ogg Vorbis; Speex is refused, and nothing is added to play
/// it) and played through `AVAudioEngine`; `AVSpeechSynthesizer` for the system voice. **Not `AVAudioPlayer`**: on
/// macOS 27.0.1 it opens Ogg Vorbis and will not play it (measured on the E2E Mac, 2026-10-15), where the converter
/// decodes it and the engine plays it to its end. `volume` is 1 for the reader; the E2E instruments set 0, which still
/// decodes, starts, runs to the end and calls back, without a sound on the shared E2E Mac.
@MainActor
public final class SystemOutput: NSObject, PronunciationOutput {
    public var onEvent: (@MainActor (OutputEvent) -> Void)?
    public let volume: Float

    private static let log = Logger(subsystem: XDictIdentity.app, category: "speech")
    /// The temporary file a recording is decoded from is named with this, and removed as soon as it is open.
    static let temporaryPrefix = "ai.xdict.recording."
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// The recording sounding now, by the number its play was given: the node calls back for a stopped or replaced one
    /// too, later, and that callback is told apart by its number.
    private var playing: Int?
    private var serial = 0
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance sounding now, held so that a late callback of a replaced one is told apart by identity.
    private var speaking: (utterance: AVSpeechUtterance, said: Utterance)?

    public init(volume: Float = 1) {
        self.volume = volume
        super.init()
        engine.attach(node)
        synthesizer.delegate = self
    }

    /// **Decodes `data` as macOS decodes audio, without a sound**: the bytes are written to a temporary file of this
    /// user's (the decoder reads files), opened, and the file removed at once; the open file is read from as it plays.
    /// `format` names the file (anything but letters and digits dropped), and the decoder believes a name: a WAV named
    /// mp3 is refused as mp3 (`kAudioFileUnsupportedDataFormatError`, measured 2026-10-15). So a refused recording is
    /// tried once more with no name, read by its content; the first refusal is the one reported.
    static func open(_ data: Data, format: String) throws -> OpenedRecording {
        let hint = String(format.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        var refusal: Int?
        for suffix in hint.isEmpty ? [""] : ["." + hint, ""] {
            do {
                return try open(data, suffix: suffix)
            } catch {
                refusal = refusal ?? (error as NSError).code
            }
        }
        throw RecordingError.undecodable(status: refusal ?? 0)
    }

    private static func open(_ data: Data, suffix: String) throws -> OpenedRecording {
        let url = FileManager.default.temporaryDirectory.appending(path: temporaryPrefix + UUID().uuidString + suffix,
                                                                   directoryHint: .notDirectory)
        try data.write(to: url, options: [.withoutOverwriting])
        defer { try? FileManager.default.removeItem(at: url) }
        return OpenedRecording(file: try AVAudioFile(forReading: url))
    }

    public func play(_ data: Data, format: String) throws -> Playback {
        let opened = try Self.open(data, format: format)
        stop()
        engine.stop()
        serial += 1
        let mine = serial
        do {
            try engine.connectNode(node, to: engine.mainMixerNode, format: opened.file.processingFormat)
            engine.mainMixerNode.outputVolume = volume
            node.scheduleFile(opened.file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.playerEnded(mine) }
            }
            try engine.start()
            try node.playAudio()
        } catch {
            node.stop()
            Self.log.error("the sound output did not start: \(String(describing: error), privacy: .public)")
            throw RecordingError.didNotStart
        }
        playing = mine
        let playback = Playback(duration: opened.duration, isPlaying: node.isPlaying, format: opened.format)
        onEvent?(.playbackStarted(playback))
        return playback
    }

    public func speak(_ text: String, with voice: VoiceInfo) -> Bool {
        guard let system = AVSpeechSynthesisVoice(identifier: voice.identifier) else {
            Self.log.notice("voice \(voice.identifier, privacy: .public) is not available; nothing spoken")
            return false
        }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = system
        utterance.volume = volume
        speaking = (utterance, Utterance(text: text, voiceIdentifier: system.identifier, voiceName: system.name,
                                         language: system.language))
        synthesizer.speak(utterance)
        return true
    }

    /// Stops what sounds, and says so at once: the system's own callback of a stopped one arrives later, and is then
    /// no longer the one sounding.
    public func stop() {
        if playing != nil {
            playing = nil
            node.stop()
            onEvent?(.playbackEnded(finished: false))
        }
        if let speaking {
            self.speaking = nil
            synthesizer.stopSpeaking(at: .immediate)
            onEvent?(.speechEnded(speaking.said, finished: false))
        }
    }

    /// **The audio frames a voice renders for `text`, into a buffer and never to the speakers**: XiaolaiDict's spike S1
    /// found a voice that resolved, "spoke" and rendered zero frames, which looks exactly like success. For the E2E
    /// instruments, beside the delegate's start and finish. Nil if the voice is not available or never finished within
    /// `limit`.
    public static func renderedFrames(of text: String, voiceIdentifier: String, within limit: Duration = .seconds(10))
        async -> Int? {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else { return nil }
        let counter = FrameCounter()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.write(utterance) { buffer in
            guard let audio = buffer as? AVAudioPCMBuffer else { return }
            counter.add(Int(audio.frameLength))
        }
        // Polled: `write` calls back on a queue of its own, and a voice that never finishes is a reading, not a hang.
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let finished = counter.finished { return finished }
            try? await Task.sleep(for: .milliseconds(20))
        }
        withExtendedLifetime(synthesizer) {}
        return nil
    }

    /// The format's four-character code as Core Audio writes it (`lpcm`, `.mp3`, `vorb`).
    nonisolated static func formatName(_ format: AVAudioFormat) -> String {
        let id = format.streamDescription.pointee.mFormatID.bigEndian
        let code = withUnsafeBytes(of: id) { String(decoding: $0, as: UTF8.self) }
        return code.trimmingCharacters(in: .whitespaces.union(.controlCharacters))
    }

    // MARK: - Callbacks, back on the main actor

    /// The engine played recording `serial` to its end: unless it was stopped or replaced first, which said so then.
    private func playerEnded(_ serial: Int) {
        guard playing == serial else { return }
        self.playing = nil
        onEvent?(.playbackEnded(finished: true))
    }

    private func speech(_ id: ObjectIdentifier, started: Bool, finished: Bool) {
        guard let speaking, ObjectIdentifier(speaking.utterance) == id else { return }
        if started {
            onEvent?(.speechStarted(speaking.said))
        } else {
            self.speaking = nil
            onEvent?(.speechEnded(speaking.said, finished: finished))
        }
    }
}

extension SystemOutput: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.speech(id, started: true, finished: false) }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.speech(id, started: false, finished: true) }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.speech(id, started: false, finished: false) }
    }
}

/// Frames counted until a zero-length buffer says the utterance is done (`write`'s own end marker).
private final class FrameCounter: @unchecked Sendable {
    // Guarded by `lock`: `write` calls back on a queue of its own, the instrument reads on the main actor.
    private let lock = NSLock()
    private var frames = 0
    private var done = false

    func add(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        if count == 0 { done = true } else { frames += count }
    }

    var finished: Int? {
        lock.lock()
        defer { lock.unlock() }
        return done ? frames : nil
    }
}

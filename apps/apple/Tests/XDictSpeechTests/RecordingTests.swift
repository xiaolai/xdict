import AVFAudio
import Foundation
import Testing
@testable import XDictSpeech

/// **A dictionary's recording, opened as macOS decodes it** (R9), without a sound: `SystemOutput.open` decodes and never
/// plays (the build Mac's speakers are the owner's; playback is proven on the E2E Mac, `sound` stage).
///
/// Measured 2026-10-15 with one recording of each format in the 25: through `AVAudioFile` (ExtAudioFile, the converter
/// `afconvert` uses) mp3 (LDOCE) 1.31 s, WAV (AHD) 1.27 s and Ogg Vorbis (OALD) 1.26 s decode on both Macs, and on the
/// E2E Mac play to their end through `AVAudioEngine` at volume 0; Speex in Ogg (CALD) is refused,
/// `kAudioFileUnsupportedDataFormatError`. **`AVAudioPlayer` is not used**: on macOS 27.0.1 (26A434) it opens Ogg Vorbis
/// and then neither prepares nor plays it (`prepareToPlay()` and `play()` false, the E2E `sound` stage's first run: every
/// OALD recording "undecodable"). The fixtures here are written by the test: no dictionary content.
@MainActor
struct RecordingTests {
    /// A mono 16-bit PCM WAV of `seconds` of silence at `rate`.
    static func wav(seconds: Double, rate: UInt32 = 8_000) -> Data {
        let samples = UInt32(Double(rate) * seconds)
        let bytes = samples * 2
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(rate)
        put(rate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        data.append(Data(count: Int(bytes)))
        return data
    }

    /// The recordings the output leaves in the temporary folder: none, ever.
    static func leftBehind() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return names.filter { $0.hasPrefix(SystemOutput.temporaryPrefix) }
    }

    @Test func aRecordingMacOSDecodesOpensWithItsDuration() throws {
        let opened = try SystemOutput.open(Self.wav(seconds: 0.5), format: "wav")
        #expect(abs(opened.duration - 0.5) < 0.01)
        #expect(opened.format == "lpcm", "\(opened.format)")
    }

    /// The name's format is a hint, never trusted: a WAV named mp3, or named nothing, or named a path, still opens.
    @Test func theNamedFormatIsOnlyAHint() throws {
        #expect(try SystemOutput.open(Self.wav(seconds: 0.25), format: "mp3").duration > 0.2)
        #expect(try SystemOutput.open(Self.wav(seconds: 0.25), format: "").duration > 0.2)
        #expect(try SystemOutput.open(Self.wav(seconds: 0.25), format: "../../x").duration > 0.2)
    }

    /// What the library's fixture holds for an "mp3" that is not one, and Speex's container with no audio in it.
    @Test func bytesMacOSCannotDecodeAreRefused() {
        for (bytes, format) in [(Data("ID3 not really a recording".utf8), "mp3"),
                                (Data("OggS\u{0}\u{2}Speex not really".utf8), "spx"), (Data(), "")] {
            #expect(throws: RecordingError.self) { try SystemOutput.open(bytes, format: format) }
        }
    }

    /// The bytes go through a temporary file only for as long as opening takes (the decoder reads a file): opened or
    /// refused, it is gone at once.
    @Test func noRecordingIsLeftInTheTemporaryFolder() throws {
        let before = Self.leftBehind()
        _ = try SystemOutput.open(Self.wav(seconds: 0.1), format: "wav")
        _ = try? SystemOutput.open(Data("not audio".utf8), format: "mp3")
        #expect(Self.leftBehind() == before)
    }

    /// Nothing opened, nothing to stop: stopping is always safe.
    @Test func stoppingWithNothingPlayingIsHarmless() {
        let output = SystemOutput(volume: 0)
        output.stop()
        #expect(output.volume == 0)
    }
}

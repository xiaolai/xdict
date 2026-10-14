import Testing
import XDictContract
import XDictLibrary

/// **Missing audio and audio macOS cannot play are told apart** (L6: "dead icons have explanations"), from the
/// resource's answer alone: a `missing` answer is missing; a found one is playable if macOS decodes its format with no
/// extra code (mp3, WAV, Ogg Vorbis and the system's own formats; `platform-architecture.md` §4a), and otherwise
/// unsupported — Speex above all, which XDict never decodes.
struct SoundDiagnosisTests {
    @Test func missingIsMissing() {
        #expect(SoundDiagnosis.of(.missing(path: "gone.mp3")) == .missing(path: "gone.mp3"))
    }

    @Test(arguments: [("a.mp3", "audio/mpeg"), ("a.wav", "audio/wav"), ("a.ogg", "audio/ogg"),
                      ("a.m4a", "application/octet-stream"), ("A.AIFF", "application/octet-stream"),
                      ("sub/a.caf", "application/octet-stream")])
    func whatMacOSDecodesIsPlayable(path: String, mime: String) {
        #expect(SoundDiagnosis.of(.found(path: path, mime: mime)) == .playable, "\(path)")
    }

    @Test func speexAndTheUnknownAreUnsupportedAndNamed() {
        #expect(SoundDiagnosis.of(.found(path: "a.spx", mime: "application/octet-stream")) == .unsupported(format: "spx"))
        #expect(SoundDiagnosis.of(.found(path: "x/a.SPX", mime: "application/octet-stream")) == .unsupported(format: "spx"))
        #expect(SoundDiagnosis.of(.found(path: "noise", mime: "application/octet-stream")) == .unsupported(format: ""))
        #expect(SoundDiagnosis.of(.found(path: "a.png", mime: "image/png")) == .unsupported(format: "png"))
    }
}

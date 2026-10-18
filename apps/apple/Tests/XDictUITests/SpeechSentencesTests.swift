import Foundation
import Testing
import XDictSearch
import XDictSpeech
import XDictUI

/// **What a sound tells the reader** (plan-macos-v1 WI-7; R8, R9, L6): a recording that plays is labelled as the
/// dictionary's; one that cannot play says why, each reason its own sentence, missing and unsupported told apart, then
/// what the system voice did instead; the voice is never passed off as the dictionary's recording. Read here in the
/// source language; both languages are `StringCatalogTests`' and the E2E `sound` stage's.
struct SpeechSentencesTests {
    static func text(_ notice: PronunciationNotice) -> [String] {
        SpeechSentences.lines(notice).map { String(localized: $0) }
    }

    static let spoken = SpeechOutcome.spoken(voice: "Samantha", language: "en-US")

    @Test func aPlayingRecordingIsLabelledAsTheDictionarys() {
        let lines = Self.text(.recording(format: "mp3"))
        #expect(lines.count == 1)
        #expect(lines.first?.contains("dictionary's own recording") == true, "\(lines)")
    }

    /// L6, and the three R9 adds: five reasons, five first lines, none the same.
    @Test func eachReasonARecordingDidNotPlayIsItsOwnSentence() {
        let problems: [RecordingProblem] = [.unsupported(format: "spx"), .missing(path: "gone.mp3"),
                                            .undecodable(format: "mp3"), .notStarted(format: "ogg"), .unavailable]
        let first = problems.map { Self.text(.fallback($0, Self.spoken)).first ?? "" }
        #expect(Set(first).count == problems.count, "\(first)")
        #expect(first[0].contains("spx") && first[1].contains("gone.mp3") && first[2].contains("mp3"))
        #expect(first[3].contains("ogg") && first[3].contains("sound output"), "\(first[3])")
    }

    /// R9: the fallback says the system voice spoke instead, and names it; it never claims to be the recording.
    @Test func aFallbackSaysTheSystemVoiceSpokeInstead() {
        let lines = Self.text(.fallback(.unsupported(format: "spx"), Self.spoken))
        #expect(lines.count == 2)
        #expect(lines.last?.contains("system voice") == true && lines.last?.contains("Samantha") == true, "\(lines)")
        #expect(lines.last?.contains("instead") == true)
        #expect(!(lines.last?.contains("recording") ?? true))
    }

    /// The voice asked for directly, and each reason it could not speak.
    @Test func eachSpeechOutcomeIsItsOwnSentence() {
        let outcomes: [SpeechOutcome] = [Self.spoken, .noLanguage, .noVoice(language: "ko"), .nothingToSay]
        let lines = outcomes.map { Self.text(.speech($0)).joined() }
        #expect(Set(lines).count == outcomes.count, "\(lines)")
        #expect(lines[1].contains("Settings"), "the reader is not told where to set the language: \(lines[1])")
    }

    /// A path the dictionary wrote can be hundreds of characters (OED's, measured); the notice shows its file name, and
    /// cuts a long one in the middle.
    @Test func aLongMissingPathIsShortened() {
        let long = "audio/audio%40file%3D_252Fsoundfiles_252Fa_252Fac_252Faci_252Faciniform_253Fpub_sig_253Dsob"
            + "FUg8pWS0KyjOwoXA4el11ZvJlgH_25252F4UxguGGyzUxE_25253D_2523_gb_1.mp32020-08-28.mp3"
        let shown = SpeechSentences.fileName(long)
        #expect(shown.count <= 48, "\(shown)")
        #expect(shown.hasSuffix(".mp3") && shown.hasPrefix("audio@file="), "\(shown)")
        #expect(SpeechSentences.fileName("us/run.mp3") == "run.mp3")
    }

    @Test func theCaveatsAreSentences() {
        let caveats: [VoiceCaveat] = [.noVoice, .compactOnly(.get("Ava")), .compactOnly(.nothingBetter),
                                      .compactOnly(.unknown)]
        let lines = caveats.map { String(localized: SpeechSentences.caveat($0)) }
        #expect(Set(lines).count == caveats.count)
        #expect(lines[1].contains("Ava") && lines[1].contains("Read & Speak") && lines[1].contains("System voice"))
        #expect(!lines[2].contains("Read & Speak"), "it offered a download that does not exist")
        #expect(!lines.joined().contains("VoiceOver Utility"), "macOS 27 downloads voices in Read & Speak")
    }

    /// R8: the speak button claims no sense-specific pronunciation.
    @Test func theSpeakButtonSaysItSpeaksTheWordAsWritten() {
        let help = String(localized: SpeechSentences.speakHelp(word: "record"))
        #expect(help.contains("record") && help.contains("system voice") && help.contains("as written"), "\(help)")
    }

    @Test func eachAccentHasAName() {
        let names = Accent.allCases.map { String(localized: SpeechSentences.accent($0)) }
        #expect(names == ["American English", "British English"])
    }
}

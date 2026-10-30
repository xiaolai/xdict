import AppKit
import SwiftUI
import XDictSpeech
import XDictTokens

/// **Speech, a pane of its own** (owner's settings audit, 2026-10-30: it was four rows inside Reading & Speech, and the
/// voice — the one thing a reader comes here to change — was a label they could not touch): the accent for English, **the
/// voice, chosen from the ones installed**, what is worth saying about it, the way to a better one, and whether a
/// dictionary's own recordings play instead. Rows in a form, the Dictionaries pane's shape.
public struct SpeechSettings: View {
    @AppStorage(SpeechPreferences.accentKey) private var accent: Accent = SpeechPreferences.defaultAccent
    @AppStorage(SpeechPreferences.voiceKey) private var voiceIdentifier = ""
    @AppStorage(SpeechPreferences.useRecordingsKey) private var useRecordings = false

    public init() {}

    public var body: some View {
        let tags = SpeechLanguage.voiceTags(declared: "en", accent: accent) ?? [accent.rawValue]
        let voices = Voices.speaking(tags, among: Voices.installed)
        Form {
            Section {
                Picker(selection: $accent) {
                    ForEach(Accent.allCases, id: \.self) { accent in
                        Text(SpeechSentences.accent(accent)).tag(accent)
                    }
                } label: {
                    Text("English accent")
                    Text("Words read aloud from an English dictionary are spoken in it.")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("accent")
                // **The voice is the reader's** (owner's settings audit, 2026-10-30): "Best available" is the old
                // behaviour — the best installed voice for the accent's tags — and a named voice overrides it wherever it
                // still speaks the language.
                Picker(selection: $voiceIdentifier) {
                    Text("Best available").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text(verbatim: voice.name).tag(voice.identifier)
                    }
                } label: {
                    Text("Voice")
                    Text("The voice installed on this Mac that reads a word aloud.")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("speech.voice")
                if let caveat = Voices.caveat(for: tags, among: Voices.installed) {
                    // **The sentence only** (owner's settings audit, 2026-10-30: the rendered pane showed this row's button
                    // beside "More voices" doing the same thing): the one action is the row below, and the sentence still
                    // names the path it takes.
                    Text(SpeechSentences.caveat(caveat))
                        .foregroundStyle(.secondary)
                }
                LabeledContent {
                    Button("Open Read & Speak Settings…") { NSWorkspace.shared.open(Voices.voiceSettingsURL) }  // placement: form-row
                        .accessibilityIdentifier("speech.openVoices")
                } label: {
                    Text("More voices")
                    Text("Download another voice, or check this one, in System Settings.")
                }
            } header: {
                Text("Voice")
            }
            .settingsAnchor(.speechVoice)
            Section {
                Toggle(isOn: $useRecordings) {
                    Text("Use the dictionary's recordings")
                    Text("Where a dictionary has its own recording of a word and macOS can play it, play that instead of the system voice.")
                }
                .accessibilityLabel(Text("Use the dictionary's recordings"))
                .accessibilityIdentifier("use-recordings")
                Text("Each dictionary is spoken in the language set for it in Settings ▸ Dictionaries.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Recordings")
            }
        }
        .settingsPane()
    }
}

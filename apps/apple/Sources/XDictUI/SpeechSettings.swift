import AppKit
import SwiftUI
import XDictSpeech

/// **Speech, in Settings** (⌘,; plan-macos-v1 WI-7, `platform-architecture.md` §4a): the reader's accent for English,
/// the voice it will use, and what is worth knowing about that voice, with the way to a better one. WI-9 builds the rest
/// of Settings around it.
public struct SpeechSettings: View {
    @AppStorage(SpeechPreferences.accentKey) private var accent: Accent = SpeechPreferences.defaultAccent
    @AppStorage(SpeechPreferences.useRecordingsKey) private var useRecordings = false

    public init() {}

    public var body: some View {
        let tags = SpeechLanguage.voiceTags(declared: "en", accent: accent) ?? [accent.rawValue]
        let voice = Voices.best(for: tags, among: Voices.installed)
        Form {
            Picker(selection: $accent) {
                ForEach(Accent.allCases, id: \.self) { accent in
                    Text(SpeechSentences.accent(accent)).tag(accent)
                }
            } label: {
                Text("English accent")
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("accent")
            LabeledContent {
                Text(verbatim: voice?.name ?? "—")
            } label: {
                Text("Voice")
            }
            if let caveat = Voices.caveat(for: tags, among: Voices.installed) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(SpeechSentences.caveat(caveat))
                        .foregroundStyle(.secondary)
                    Button("Open Read & Speak Settings") { NSWorkspace.shared.open(Voices.voiceSettingsURL) }
                }
            }
            Toggle(isOn: $useRecordings) {
                Text("Use the dictionary's recordings")
                Text("Where a dictionary has its own recording of a word and macOS can play it, play that instead of the system voice.")
            }
            .accessibilityIdentifier("use-recordings")
            Text("Each dictionary is spoken in the language set for it in the Library.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}

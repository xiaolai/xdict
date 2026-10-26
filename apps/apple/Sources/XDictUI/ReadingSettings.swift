import SwiftUI
import XDictEntryView

/// **Reading & Speech, in Settings** (⌘,; ADR-0012 d.1): the reading style's accent, the one colour a dictionary's
/// coloured text is drawn in (owner, 2026-10-16), an open entry taking a new choice at once; then the speech rows
/// (`SpeechSettings`), in one form.
public struct ReadingSettings: View {
    @AppStorage(EntryPreferences.accentKey) private var accent: EntryReadingFrame.Accent = .teal
    @AppStorage(EntryPreferences.comfortableWidthKey) private var comfortableWidth = false
    /// **Whether the phrase row is asked for at all** (owner Q2, 2026-10-26; plan-context-tools D3; same key the window
    /// reads). Off, the captured sentence never reaches the dictionary service for matching.
    @AppStorage(SearchWindowState.phrasesShownKey) private var showPhrases = true

    public init() {}

    public var body: some View {
        Form {
            Toggle(isOn: $comfortableWidth) {
                Text("Comfortable reading width")
                Text("Shorten long lines in wide windows. Original style and lookup popups keep their own width.")
            }
            .accessibilityIdentifier("reading.comfortable-width")
            .settingsAnchor(.readingWidth)
            Toggle(isOn: $showPhrases) {
                Text("Show phrases while reading")
                Text("Notice when the sentence you capture holds a phrase your dictionaries know, and keep it as a card. Off, the sentence is not sent to XDict’s dictionary service for matching.")
            }
            .accessibilityIdentifier("reading.show-phrases")
            .settingsAnchor(.readingPhrases)
            Picker(selection: $accent) {
                // Each choice shows its colour: the swatch is the content (UI review S-03).
                ForEach(EntryReadingFrame.Accent.allCases, id: \.self) { accent in
                    Label {
                        Text(Self.name(accent))
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(Self.swatch(accent)).accessibilityHidden(true)
                    }
                    .tag(accent)
                }
            } label: {
                Text("Accent color")
                Text("The color a dictionary's colored words are drawn in.")
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("accent-colour")
            .settingsAnchor(.readingAccent)
            Section { SpeechSettings() }
                .settingsAnchor(.speechVoice)
        }
        // As tall as its rows: a grouped form scrolls and would take the window's height, leaving it mostly empty.
        .settingsPane()
    }

    static func swatch(_ accent: EntryReadingFrame.Accent) -> Color {
        switch accent {
        case .teal: .teal
        case .red: .red
        case .indigo: .indigo
        }
    }

    static func name(_ accent: EntryReadingFrame.Accent) -> LocalizedStringKey {
        switch accent {
        case .teal: "Teal"
        case .red: "Red"
        case .indigo: "Indigo"
        }
    }
}

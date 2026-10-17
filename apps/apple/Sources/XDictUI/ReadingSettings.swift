import SwiftUI
import XDictEntryView

/// **Reading, in Settings** (⌘,): the reading style's accent, the one colour a dictionary's coloured text is drawn in
/// (owner, 2026-10-16). Kept with the other reading preferences; an open entry takes a new choice at once.
public struct ReadingSettings: View {
    @AppStorage(EntryPreferences.accentKey) private var accent: EntryReadingFrame.Accent = .teal

    public init() {}

    public var body: some View {
        Form {
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

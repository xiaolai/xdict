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
                ForEach(EntryReadingFrame.Accent.allCases, id: \.self) { accent in
                    Text(Self.name(accent)).tag(accent)
                }
            } label: {
                Text("Accent colour")
                Text("The colour a dictionary's coloured words are drawn in.")
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("accent-colour")
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    static func name(_ accent: EntryReadingFrame.Accent) -> LocalizedStringKey {
        switch accent {
        case .teal: "Teal"
        case .red: "Red"
        case .indigo: "Indigo"
        }
    }
}

import SwiftUI
import XDictTokens

/// **Settings ▸ Learning** (ADR-0023; plan-history-and-learning §2.7): the history's switch, the languages a reading must
/// be in to be recorded, and the languages the drawer shows. The two language sets are separate on purpose, and neither
/// rewrites or deletes what is stored: a reader may keep every language and read one.
public struct LearningSettings: View {
    @State private var preferences = LearningPreferences.shared
    private let declared: @MainActor () -> [String]

    /// `declared` is the library's search-side languages, read when the pane draws: the library may still be loading.
    public init(declared: @escaping @MainActor () -> [String]) {
        self.declared = declared
    }

    public var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle("Keep a reading history on this Mac", isOn: $preferences.historyEnabled)
                    .accessibilityIdentifier("learning.history")
                Text("The sentence around a looked-up word is stored only on this Mac. Nothing is sent anywhere; turning the history off stops new readings and keeps the ones already here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Reading History")
            }

            if preferences.historyEnabled {
                languageSection("Languages to record",
                                note: "With no language chosen, readings in every language are kept.",
                                chosen: preferences.targetLanguages,
                                setting: { preferences.setTargetLanguages($0) })
                languageSection("Languages to show",
                                note: "With no language chosen, the drawer shows every reading.",
                                chosen: preferences.drawerLanguages,
                                setting: { preferences.setDrawerLanguages($0) })
            }
        }
        .settingsPane()
    }

    private func languageSection(_ title: LocalizedStringResource, note: LocalizedStringResource, chosen: [String],
                                 setting: @escaping ([String]) -> Void) -> some View {
        let declaredLanguages = declared()
        // A language the library stops declaring stays in the setting, and is shown as no longer present (plan §2.7).
        let offered = LearningPreferences.unique(declaredLanguages + chosen).sorted()
        return Section {
            if offered.isEmpty {
                Text("Your dictionaries declare no language yet, so every reading is kept.")
                    .foregroundStyle(.secondary)
            }
            ForEach(offered, id: \.self) { language in
                Toggle(isOn: Binding(get: { chosen.contains(language) },
                                     set: { on in
                                         var next = chosen
                                         if on, !next.contains(language) { next.append(language) }
                                         if !on { next.removeAll { $0 == language } }
                                         setting(next)
                                     })) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
                        Text(verbatim: Self.name(language))
                        if !declaredLanguages.contains(language) {
                            Text("No longer in your library")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(title)
        }
    }

    /// A language code as the reader's own locale names it; the empty code (a dictionary that declares none) as unknown.
    static func name(_ code: String) -> String {
        guard !code.isEmpty else { return String(localized: "Unknown") }
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

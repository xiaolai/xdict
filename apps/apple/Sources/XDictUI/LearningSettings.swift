import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XDictContract
import XDictTokens

/// **Settings ▸ Learning** (ADR-0023; plan-history-and-learning §2.7, §5.4, §5.5): the history's switch, the languages a
/// reading must be in to be recorded, the languages the drawer shows, review reminders, and the reader's own data — export
/// and erase. The two language sets are separate on purpose, and neither rewrites or deletes what is stored: a reader may
/// keep every language and read one.
public struct LearningSettings: View {
    @State private var preferences = LearningPreferences.shared
    @State private var status: String?
    @State private var syncStatus: String?
    private let declared: @MainActor () -> [String]
    private let study: StudyModel?
    private let reminders: ReviewReminders?
    private let performSync: (@MainActor (String) async -> SyncReport?)?

    /// `declared` is the library's search-side languages, read when the pane draws: the library may still be loading.
    /// `study` exports and erases; `reminders` delivers the review's reminder. Both nil leave their section out.
    public init(declared: @escaping @MainActor () -> [String], study: StudyModel? = nil,
                reminders: ReviewReminders? = nil, performSync: (@MainActor (String) async -> SyncReport?)? = nil) {
        self.declared = declared
        self.study = study
        self.reminders = reminders
        self.performSync = performSync
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
            if let reminders {
                reminderSection(reminders)
            }
            if let study {
                if performSync != nil { syncSection }
                dataSection(study)
            }
        }
        .settingsPane()
    }

    /// **Review reminders** (plan §5.4): the switch asks the system once; a refusal is said here rather than the reminder
    /// quietly never arriving.
    private func reminderSection(_ reminders: ReviewReminders) -> some View {
        Section {
            Toggle("Remind me when cards are due", isOn: Binding(
                get: { preferences.remindersEnabled },
                set: { on in Task { await reminders.setEnabled(on) } }))
                .accessibilityIdentifier("learning.reminders")
            if reminders.refused {
                Text("macOS is not allowing XDict's notifications. Allow them in System Settings ▸ Notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Review Reminders")
        }
    }

    /// **Sync with the reader's other devices** (plan §2.6): another device's log merges in, then this Mac's whole log is
    /// written to the folder for them. The folder is the reader's own storage; XDict keeps no server and no account.
    @ViewBuilder private var syncSection: some View {
        Section {
            if let bookmark = preferences.syncFolder {
                ActionRow {
                    Text(verbatim: SyncFolder.name(bookmark) ?? "")
                } actions: {
                    Button("Sync Now") { syncNow() }
                        .accessibilityIdentifier("learning.syncNow")
                }
                ActionRow {
                    Text("Another folder can be chosen; what is already here is left alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } actions: {
                    Button("Choose Folder…") { chooseSyncFolder() }
                }
            } else {
                ActionRow {
                    Text("Choose a folder in your own storage — iCloud Drive, a WebDAV mount — and your readings, notes and grades sync with your other devices through it.")
                } actions: {
                    Button("Choose Folder…") { chooseSyncFolder() }
                        .accessibilityIdentifier("learning.syncChoose")
                }
            }
            if let syncStatus {
                Text(verbatim: syncStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("learning.sync.status")
            }
        } header: {
            Text("Sync")
        }
    }

    private func chooseSyncFolder() {
        guard let chosen = SyncFolder.choose() else { return }
        preferences.setSyncFolder(chosen.bookmark)
        syncStatus = nil
    }

    private func syncNow() {
        guard let performSync else { return }
        guard let bookmark = preferences.syncFolder, let folder = SyncFolder.open(bookmark) else {
            syncStatus = String(localized: "No sync folder yet.")
            return
        }
        Task {
            defer { folder.stop() }
            guard let report = await performSync(folder.path) else {
                syncStatus = String(localized: "The sync could not finish.")
                return
            }
            syncStatus = report.peers == 0
                ? String(localized: "No other device's log is in this folder yet.")
                : String(localized: "Synced: \(report.added) new events.")
        }
    }

    /// **The reader's own data** (plan §5.5): one export, and an erase that names what it cleared and what may remain.
    private func dataSection(_ study: StudyModel) -> some View {
        Section {
            ActionRow {
                Text("Your readings, notes and grades, as one JSON file.")
            } actions: {
                Button("Export…") { export(study) }
                    .accessibilityIdentifier("learning.export")
            }
            ActionRow {
                Text("Erase every reading, note and grade kept on this Mac.")
            } actions: {
                Button("Erase…") { erase(study) }
                    .accessibilityIdentifier("learning.erase")
            }
            if let status {
                Text(verbatim: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("learning.data.status")
            }
        } header: {
            Text("Your Data")
        }
    }

    private func export(_ study: StudyModel) {
        Task {
            guard let json = await study.export() else {
                status = String(localized: "The data could not be exported.")
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "XDict Learning Data.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try Data(json.utf8).write(to: url)
                status = String(localized: "Exported to \(url.lastPathComponent).")
            } catch {
                status = String(localized: "The file could not be written.")
            }
        }
    }

    private func erase(_ study: StudyModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Erase all learning data?")
        alert.informativeText = String(localized: "Every reading, note and grade on this Mac is erased. This cannot be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Cancel"))  // placement: system-alert
        alert.addButton(withTitle: String(localized: "Erase"))  // placement: system-alert
        // Cancel is the default, at Return: an erase is never one keystroke away (R3).
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task {
            guard let report = await study.erase() else {
                status = String(localized: "Nothing was erased.")
                return
            }
            status = Self.eraseSentence(report)
        }
    }

    /// What an erase cleared, and what only the system can reclaim (ADR-0024): never more than the receipt says. One
    /// sentence per count, so each agrees with its own noun.
    static func eraseSentence(_ report: StudyEraseReport) -> String {
        var parts: [String] = []
        if report.clearedReadings > 0 {
            parts.append(String(localized: "\(report.clearedReadings) readings erased."))
        }
        if report.clearedNotes > 0 {
            parts.append(String(localized: "\(report.clearedNotes) notes erased."))
        }
        if report.clearedGrades > 0 {
            parts.append(String(localized: "\(report.clearedGrades) grades erased."))
        }
        if parts.isEmpty { parts.append(String(localized: "Nothing was erased.")) }
        switch report.recoverable {
        case .freeBlocks:
            parts.append(String(localized: "Their bytes may remain in free blocks, snapshots and backups, which only macOS can reclaim."))
        }
        return parts.joined(separator: " ")
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

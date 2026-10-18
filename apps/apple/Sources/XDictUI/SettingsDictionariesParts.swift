import SwiftUI
import XDictEntryView
import XDictLibrary
import XDictTokens

/// **The strip above the table** (ADR-0012 d.2): why the library itself cannot be used, a dictionary asked for that has
/// gone, each import under way with its progress and Cancel, and what the last addition could not do — the Library
/// window's banner, row progress and notice bar, in one place.
struct SettingsLibraryStrip: View {
    let library: Library
    let route: SettingsRoute
    @State private var showsNotices = false

    var body: some View {
        let underWay = SettingsDictionaries.underWay(order: library.entries.map(\.id), phases: library.phases)
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            if let unreadable = library.unreadable {
                line(symbol: "exclamationmark.triangle") { Text(LibrarySentences.unreadable(unreadable)) }
            }
            if route.removedNotice {
                line(symbol: "info.circle") { Text(SettingsDictionaries.removedNotice) }
            }
            ForEach(underWay, id: \.self) { id in
                if let entry = library.entries.first(where: { $0.id == id }), let phase = library.phases[id] {
                    progress(entry, phase)
                }
            }
            notices
        }
    }

    private func line(symbol: String, @ViewBuilder text: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            text().frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .font(.subheadline)
    }

    /// One import under way: its name, how far, and Cancel while it can be cancelled.
    private func progress(_ entry: LibraryEntry, _ phase: EntryPhase) -> some View {
        HStack(spacing: Tokens.Space.sm) {
            Text(verbatim: entry.displayName).lineLimit(1)
            if case .importing(let done, let total) = phase, total > 0 {
                ProgressView(value: Double(done), total: Double(total)) {
                    Text(LibrarySentences.phase(phase))
                }
                .controlSize(.small)
            } else {
                Text(LibrarySentences.phase(phase)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            if LibraryRowAction.for(phase) == .cancel {
                Button { Task { await library.cancelImport(entry.id) } } label: { Text("Cancel") }
                    .controlSize(.small)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.progress")
    }

    /// **What the last addition could not do, as one line** (UI review X7): one notice says itself, several are
    /// counted, each listed with its reason behind Show Details….
    @ViewBuilder private var notices: some View {
        let notices = library.notices
        if !notices.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Group {
                    if notices.count == 1, let only = notices.first {
                        Text(LibrarySentences.notice(only))
                    } else {
                        Text(LibrarySentences.noticesHeadline(notices.count))
                    }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                Button("Show Details…") { showsNotices = true }
                    .controlSize(.small)
                    .popover(isPresented: $showsNotices) { noticeDetails }
                Button("Dismiss") { for notice in notices { library.dismiss(notice) } }
                    .controlSize(.small)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.notices")
        }
    }

    private var noticeDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                ForEach(Array(library.notices.enumerated()), id: \.offset) { _, notice in
                    Text(LibrarySentences.notice(notice)).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .frame(width: Tokens.Window.noticesPopoverWidth)
        .frame(maxHeight: Tokens.Window.noticesPopoverMaxHeight)
    }
}

/// **Apple's `+`/`−` under the table** (ADR-0012 d.2): `+` a menu of what can be added, `−` removes the selected one,
/// undoably. Icons, their names as tooltips and for VoiceOver.
struct SettingsAddRemoveBar: View {
    let canAdd: Bool
    let canRemove: Bool
    let add: (SettingsDictionaries.AddItem) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(SettingsDictionaries.addMenu, id: \.self) { item in
                    if item.opensWithCommandO {
                        Button { add(item) } label: { Text(item.title) }.keyboardShortcut("o")
                    } else {
                        Button { add(item) } label: { Text(item.title) }
                    }
                }
            } label: {
                Image(systemName: "plus").frame(width: Tokens.Size.tableButton.width, height: Tokens.Size.tableButton.height)
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!canAdd)
            .help(Text("Add Dictionaries…"))
            .accessibilityLabel(Text("Add Dictionaries…"))
            .accessibilityIdentifier("settings.add")
            Button(action: remove) {
                Image(systemName: "minus").frame(width: Tokens.Size.tableButton.width, height: Tokens.Size.tableButton.height).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .help(Text("Remove"))
            .accessibilityLabel(Text("Remove"))
            .accessibilityIdentifier("settings.remove")
            Spacer()
        }
    }
}

/// **The selected dictionary, beneath the table** (P40; ADR-0012 d.2): its one current problem with the action that
/// can fix it — the changed-file question, a file gone or refused, languages to confirm — then its option, Original
/// style, and Details….
struct SettingsDictionaryOptions: View {
    let library: Library
    let entry: LibraryEntry
    let details: () -> Void
    let locate: () -> Void
    @AppStorage private var originalStyle: Bool

    init(library: Library, entry: LibraryEntry, details: @escaping () -> Void, locate: @escaping () -> Void) {
        self.library = library
        self.entry = entry
        self.details = details
        self.locate = locate
        _originalStyle = AppStorage(wrappedValue: false, EntryPreferences.originalStyleKey(entry.preferencesKey))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            problem
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: $originalStyle) { Text("Original style") }
                    .toggleStyle(.checkbox)
                    .help(Text("Show this dictionary's entries as its own stylesheets draw them, instead of in XDict's reading style. Links and protections are the same either way."))
                    .accessibilityIdentifier("original-style")
                Spacer()
                Button(action: details) { Text(SettingsDictionaries.details) }
                    .accessibilityIdentifier("settings.details")
            }
        }
    }

    /// One problem at a time, the most pressing first: the changed file's question, then why it cannot be used, then the
    /// languages to confirm.
    @ViewBuilder private var problem: some View {
        let phase = library.phases[entry.id]
        if entry.offer != nil {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("The file of this dictionary changed. Is it still the same dictionary?")
                HStack {
                    Button("Same Dictionary") { Task { _ = await library.acceptJoin(entry.id) } }
                    Button("A Different Dictionary") { library.declineJoin(entry.id) }
                }
            }
        } else if entry.join != nil {
            HStack {
                Text("Kept as the same dictionary as the file it replaced.")
                Spacer()
                Button("Undo") { Task { _ = await library.undoJoin(entry.id) } }
            }
        } else if let sentence = ProblemStatus.sentence(for: phase) {
            HStack(alignment: .firstTextBaseline) {
                ProblemStatus(sentence: sentence)
                Spacer()
                switch LibraryRowAction.for(phase) {
                case .locate: Button("Locate…") { locate() }
                case .showInFinder: Button("Show in Finder") { LibraryRowAction.showInFinder(entry) }
                case .tryAgain: Button("Try Again") { library.retry(entry.id) }
                case .cancel, .none: EmptyView()
                }
            }
        } else if case .ready = phase, entry.languages.needsAsking {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.languages.basis == .unknown
                     ? LocalizedStringResource("XDict could not tell this dictionary's languages from its file name. Which are they?")
                     : LocalizedStringResource("XDict guessed these languages from the file name. Are they right?"))
                Spacer()
                if entry.languages.pair.search != nil, entry.languages.pair.explanation != nil {
                    Button("Confirm") { library.confirmLanguages(entry.id) }
                } else {
                    Button(action: details) { Text(SettingsDictionaries.details) }
                }
            }
        }
    }
}

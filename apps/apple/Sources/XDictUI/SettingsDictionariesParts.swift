import SwiftUI
import XDictContract
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

    /// One import under way (R2): its name and how far, over the bar where there is a count, and Cancel at the trailing
    /// edge while it can be cancelled.
    private func progress(_ entry: LibraryEntry, _ phase: EntryPhase) -> some View {
        ProgressRow(bar: Self.bar(phase)) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.sm) {
                Text(verbatim: entry.displayName).lineLimit(1)
                Text(LibrarySentences.phase(phase)).foregroundStyle(.secondary).lineLimit(1)
            }
        } control: {
            if LibraryRowAction.for(phase) == .cancel {
                Button { Task { await library.cancelImport(entry.id) } } label: { Text("Cancel") }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.progress")
    }

    /// An import's bar: how far by its count; none before it has one.
    static func bar(_ phase: EntryPhase) -> ProgressBar {
        if case .importing(let done, let total) = phase { ProgressBar.of(done: done, total: total) } else { .none }
    }

    /// **What the last addition could not do, as one line** (UI review X7): one notice says itself, several are
    /// counted, each listed with its reason behind Show Details….
    @ViewBuilder private var notices: some View {
        let notices = library.notices
        if !notices.isEmpty {
            // R2: the strip's actions small at the trailing edge, Dismiss the primary one, rightmost.
            ActionRow(.strip) {
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
                    .lineLimit(2)
                }
            } secondary: {
                Button("Show Details…") { showsNotices = true }
                    .popover(isPresented: $showsNotices) { noticeDetails }
            } primary: {
                Button("Dismiss") { for notice in notices { library.dismiss(notice) } }
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
        HStack(spacing: 0) {  // placement: P39
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
    /// Convert Again for an Apple dictionary Apple updated (ADR-0011 decision 8); nil where it cannot be offered.
    let convertAgain: (() -> Void)?
    /// What this dictionary's conversion is doing now, and Cancel for it; nil when none runs.
    let conversion: AppleConversionLine?
    let cancelConversion: (() -> Void)?
    @AppStorage private var originalStyle: Bool

    init(library: Library, entry: LibraryEntry, details: @escaping () -> Void, locate: @escaping () -> Void,
         convertAgain: (() -> Void)? = nil, conversion: AppleConversionLine? = nil,
         cancelConversion: (() -> Void)? = nil) {
        self.library = library
        self.entry = entry
        self.details = details
        self.locate = locate
        self.convertAgain = convertAgain
        self.conversion = conversion
        self.cancelConversion = cancelConversion
        _originalStyle = AppStorage(wrappedValue: false, EntryPreferences.originalStyleKey(entry.preferencesKey))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            problem
            ForEach(SettingsDictionaries.displayOptionRows(library.displayOptions[entry.id], edition: entry.edition),
                    id: \.id) { declared in
                if let option = EntryDisplayOption(declared) {
                    SettingsDisplayOptionRow(option: option, dictionary: entry.preferencesKey)
                }
            }
            ActionRow {
                Toggle(isOn: $originalStyle) { Text("Original style") }
                    .toggleStyle(.checkbox)
                    .help(Text("Show this dictionary's entries as its own stylesheets draw them, instead of in XDict's reading style. Links and protections are the same either way."))
                    .accessibilityIdentifier("original-style")
            } actions: {
                Button(action: details) { Text(SettingsDictionaries.details) }
                    .accessibilityIdentifier("settings.details")
            }
        }
        .task(id: entry.edition) { await library.loadDisplayOptions(entry.id) }
    }

    /// Convert Again under way (or failed), where its button was: a bar with the service's count, and Cancel.
    @ViewBuilder private func conversionLine(_ line: AppleConversionLine) -> some View {
        switch line {
        case .working(let fraction, let cancellable):
            // A progress row (R2): the sentence over the bar, the bar taking the width, Cancel small at its own size at the
            // trailing edge, as an import's in the strip above (R4).
            ProgressRow(bar: ProgressBar.of(fraction: fraction)) {
                Text(AppleImportSentences.converting(name: entry.displayName)).foregroundStyle(.secondary)
            } control: {
                if cancellable, let cancelConversion {
                    Button(action: cancelConversion) { Text("Cancel") }
                        .accessibilityIdentifier("settings.convertCancel")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.convertProgress")
        case .failed(let failure):
            ActionRow {
                Text(AppleImportSentences.failure(failure)).foregroundStyle(.secondary)
            } actions: {
                if let convertAgain {
                    Button(action: convertAgain) { Text("Try Again") }
                        .accessibilityIdentifier("settings.convertAgain")
                }
            }
        }
    }

    /// One problem at a time, the most pressing first: the changed file's question, then why it cannot be used, then an
    /// Apple dictionary Apple updated or removed (ADR-0011 decisions 7–9), then the languages to confirm.
    @ViewBuilder private var problem: some View {
        let phase = library.phases[entry.id]
        if let conversion {
            conversionLine(conversion)
        } else if entry.offer != nil {
            // A question and its two answers (R1): the primary one, Same Dictionary, rightmost.
            ActionRow {
                Text("The file of this dictionary changed. Is it still the same dictionary?")
            } secondary: {
                Button("A Different Dictionary") { library.declineJoin(entry.id) }
            } primary: {
                Button("Same Dictionary") { Task { _ = await library.acceptJoin(entry.id) } }
            }
        } else if entry.join != nil {
            ActionRow {
                Text("Kept as the same dictionary as the file it replaced.")
            } actions: {
                Button("Undo") { Task { _ = await library.undoJoin(entry.id) } }
            }
        } else if let sentence = ProblemStatus.sentence(for: phase) {
            ActionRow {
                ProblemStatus(sentence: sentence)
            } actions: {
                switch LibraryRowAction.for(phase) {
                case .locate: Button("Locate…") { locate() }
                case .showInFinder: Button("Show in Finder") { LibraryRowAction.showInFinder(entry) }
                case .tryAgain: Button("Try Again") { library.retry(entry.id) }
                case .cancel, .none: EmptyView()
                }
            }
        } else if library.appleStatus[entry.id] == .updated {
            ActionRow {
                Text(AppleImportSentences.updated(name: entry.displayName))
            } actions: {
                if let convertAgain {
                    Button(action: convertAgain) { Text(AppleImportSentences.convertAgain) }
                        .help(Text(AppleImportSentences.convertAgainHelp))
                        .accessibilityIdentifier("settings.convertAgain")
                }
            }
        } else if library.appleStatus[entry.id] == .removed {
            Text(AppleImportSentences.removed).foregroundStyle(.secondary)
        } else if case .ready = phase, entry.languages.needsAsking {
            ActionRow {
                Text(entry.languages.basis == .unknown
                     ? LocalizedStringResource("XDict could not tell this dictionary's languages from its file name. Which are they?")
                     : LocalizedStringResource("XDict guessed these languages from the file name. Are they right?"))
            } actions: {
                if entry.languages.pair.search != nil, entry.languages.pair.explanation != nil {
                    Button("Confirm") { library.confirmLanguages(entry.id) }
                } else {
                    Button(action: details) { Text(SettingsDictionaries.details) }
                }
            }
        }
    }
}

/// **One display option of the selected dictionary** (ADR-0013 d.6), as Apple's dictionary panes offer theirs: a pop-up
/// of its values. It shows the effective choice (the stored intent where this edition declares it, else the edition's
/// default) and stores the reader's pick as intent under the lineage, where the entry view reads it.
struct SettingsDisplayOptionRow: View {
    let option: EntryDisplayOption
    @AppStorage private var stored: String?

    init(option: EntryDisplayOption, dictionary: String) {
        self.option = option
        _stored = AppStorage(EntryPreferences.displayChoiceKey(option.id, dictionary))
    }

    var body: some View {
        Picker(selection: Binding(get: { EntryPreferences.effective(stored, of: option) }, set: { stored = $0 })) {
            ForEach(option.values, id: \.self) { value in
                if let name = SettingsDictionaries.optionValue(option.id, value) { Text(name).tag(value) }
            }
        } label: {
            if let title = SettingsDictionaries.optionTitle(option.id) { Text(title) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityIdentifier("settings.option.\(option.id)")
    }
}

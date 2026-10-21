import AppKit
import SwiftUI
import XDictContract
import XDictEntryView
import XDictLibrary
import XDictTokens

/// **One dictionary's details**: the question a changed file asks (and the undo of its answer), the reader's name for
/// it, its languages (asked when the file name did not state them, L3), its About from the header (R11: title,
/// description, format, entries, edition), what the reader should know about its files, and the files themselves.
/// Remove from Library is the sheet's, apart at its footer's leading edge (R3, `SheetFooter`).
struct LibraryDetail: View {
    let library: Library
    let entry: LibraryEntry
    /// Locate… (the open panel), as the Library list does it.
    let locate: () -> Void
    /// What the last join did to the reader's notes (plan §5.1); nil leaves the sentence out.
    let study: StudyModel?
    /// ADR-0010 Q3: this dictionary in its own style, kept under its lineage (never its path), off by default.
    @AppStorage private var originalStyle: Bool

    init(library: Library, entry: LibraryEntry, locate: @escaping () -> Void = {}, study: StudyModel? = nil) {
        self.library = library
        self.entry = entry
        self.locate = locate
        self.study = study
        _originalStyle = AppStorage(wrappedValue: false, EntryPreferences.originalStyleKey(entry.preferencesKey))
    }

    /// The languages the reader is offered: XDict's own two, and those dictionaries most often pair them with. Named by
    /// the system in the reader's language.
    static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "la", "ar"]

    var body: some View {
        // Status first, then the reader's choices, then what XDict knows of it (UI review L-02, L-10).
        Form {
            problem
            if let offer = entry.offer { joinQuestion(offer) }
            if entry.join != nil { joined }
            if let summary = study?.lastReanchor, summary.to == entry.edition { notesFollowed(summary) }
            Section {
                TextField(text: Binding(get: { entry.readersName ?? "" }, set: { library.rename(entry.id, $0) }),
                          prompt: Text(verbatim: DisplayName.of(readers: nil, title: entry.info?.title ?? "",
                                                                fileName: entry.mdx?.fileName ?? ""))) {
                    Text("Name")
                }
                .accessibilityLabel(Text("Name"))
            }
            // What only an opened dictionary has: hidden for one that never opened (L-02).
            if entry.info != nil {
                languages
                reading
            }
            // No About for a dictionary that never opened: it would only say so (Codex §5).
            if entry.info != nil || entry.edition != nil { about }
            health
            if !entry.notes.isEmpty {
                Section("Problems") {
                    ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                        Text(LibrarySentences.note(note)).textSelection(.enabled)
                    }
                }
            }
            Section("Files") {
                ForEach(entry.files, id: \.id) { file in
                    Text(verbatim: file.fileName).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// What the reading style does to this dictionary (ADR-0010, owner's decision of 2026-10-17): asked of the service
    /// when these details show. The dictionary's own words (families, selectors, sheet paths) are shown as written.
    @ViewBuilder private var readingStyle: some View {
        DisclosureGroup {
            if let state = library.readingStyles[entry.id] {
                Text(LibrarySentences.styleStatus(state)).textSelection(.enabled)
                if case .read(let style) = state {
                    Text(LibrarySentences.baseSize(px: style.basePx, from: style.baseFrom)).textSelection(.enabled)
                    if !style.fonts.isEmpty {
                        DisclosureGroup {
                            ForEach(Array(style.fonts.enumerated()), id: \.offset) { _, font in
                                VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                                    Text(verbatim: font.family).font(.callout.bold())
                                    Text(LibrarySentences.fontReason(font.reason)).font(.caption)
                                    Text(verbatim: font.selector).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                .textSelection(.enabled)
                            }
                        } label: {
                            Text("Fonts kept: \(style.fonts.count)")
                        }
                    }
                    DisclosureGroup {
                        ForEach(Array(style.sheets.enumerated()), id: \.offset) { _, sheet in
                            Text(verbatim: sheet).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        ForEach(Array(style.skipped.enumerated()), id: \.offset) { _, skipped in
                            // The reader's sentence, then the core's own English beneath it, as a diagnostic only.
                            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                                Text(LibrarySentences.skipped(skipped)).font(.caption)
                                if let detail = LibrarySentences.skippedDetail(skipped) {
                                    Text(verbatim: detail).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                }
                            }
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        }
                    } label: {
                        Text("Style sheets read: \(style.sheets.count), skipped: \(style.skipped.count)")
                    }
                    ForEach(Array(LibrarySentences.styleChanges(style.changes).enumerated()), id: \.offset) { _, line in
                        Text(line).textSelection(.enabled)
                    }
                }
            }
        } label: {
            Text("What the reading style changes")
        }
        .task(id: entry.id) { await library.loadReadingStyle(entry.id) }
    }

    /// Why this dictionary cannot be used, in full, and the action that can fix it (UI review L-02, X3).
    @ViewBuilder private var problem: some View {
        let phase = library.phases[entry.id]
        if let sentence = ProblemStatus.sentence(for: phase) {
            // Which dictionary first, its file beneath, then why and what to do (Codex §5).
            Section {
                VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                    Text(verbatim: entry.displayName).font(.headline)
                    if let file = entry.mdx?.fileName {
                        Text(verbatim: file).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
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
            }
        }
    }

    /// What the health check found (WI-12): where it is, then one sentence per finding, each opening to its places.
    @ViewBuilder private var health: some View {
        if let state = library.health[entry.id] {
            Section("Health") {
                if case .missing = library.phases[entry.id] {
                    // What it says was true of the file when it was there (L-02).
                    Text("Last checked when the file was there.").foregroundStyle(.secondary)
                }
                Text(LibrarySentences.healthStatus(state)).textSelection(.enabled)
                if case .checked(let report) = state {
                    ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
                        if finding.examples.isEmpty {
                            Text(LibrarySentences.health(finding)).textSelection(.enabled)
                        } else {
                            DisclosureGroup {
                                ForEach(Array(finding.examples.enumerated()), id: \.offset) { _, example in
                                    VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                                        Text(verbatim: example.key).font(.callout.bold())
                                        Text(verbatim: example.text).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    .textSelection(.enabled)
                                }
                            } label: {
                                Text(LibrarySentences.health(finding))
                            }
                        }
                    }
                }
            }
        }
    }

    private func joinQuestion(_ offer: JoinOffer) -> some View {
        Section {
            // The question leads, its two answers trailing, the primary one rightmost (R1); Return stays the sheet's
            // Done (R3).
            ActionRow {
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text("The file of this dictionary changed. Is it still the same dictionary?")
                    Text("""
                        If it is, what you keep about it carries over. If not, it becomes a dictionary of its own. You \
                        can change your mind afterwards.
                        """)
                        .font(.callout).foregroundStyle(.secondary)
                }
            } secondary: {
                Button("A Different Dictionary") { library.declineJoin(entry.id) }
            } primary: {
                Button("Same Dictionary") { Task { _ = await library.acceptJoin(entry.id) } }
            }
        }
    }

    /// **Where the reader's notes went** (plan §5.1): the count that followed this edition, and the count that could not
    /// be found in it — a changed, reordered or missing definition never binds another record.
    private func notesFollowed(_ summary: StudyModel.ReanchorSummary) -> some View {
        let moved = summary.report.outcomes.filter { $0.result == .reanchored }.count
        let left = summary.report.outcomes.count - moved
        return Section {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                if moved > 0 {
                    Text("\(moved) notes now point to this edition.")
                }
                if left > 0 {
                    Text("\(left) notes could not be found in this edition and stay on the old one.")
                }
            }
            .font(.callout)
        } header: {
            Text("Notes")
        }
    }

    private var joined: some View {
        Section {
            ActionRow {
                Text("Kept as the same dictionary as the file it replaced.")
            } actions: {
                Button("Undo") { Task { _ = await library.undoJoin(entry.id) } }
            }
        }
    }

    private var languages: some View {
        Section("Languages") {
            if entry.languages.needsAsking {
                ActionRow {
                    Text(entry.languages.basis == .unknown
                         ? LocalizedStringResource("XDict could not tell this dictionary's languages from its file name. Which are they?")
                         : LocalizedStringResource("XDict guessed these languages from the file name. Are they right?"))
                } actions: {
                    Button("Confirm") { library.confirmLanguages(entry.id) }
                        .disabled(entry.languages.pair.search == nil || entry.languages.pair.explanation == nil)
                }
            }
            Picker(selection: language(\.search)) {
                choices
            } label: {
                Text("Search in")
            }
            Picker(selection: language(\.explanation)) {
                choices
            } label: {
                Text("Explained in")
            }
        }
    }

    @ViewBuilder private var choices: some View {
        Text("Not Set").tag(String?.none)
        ForEach(Self.languages, id: \.self) { code in
            Text(verbatim: Locale.current.localizedString(forIdentifier: code) ?? code).tag(Optional(code))
        }
    }

    private func language(_ side: WritableKeyPath<LanguagePair, String?>) -> Binding<String?> {
        Binding(get: { entry.languages.pair[keyPath: side] }, set: { chosen in
            var pair = entry.languages.pair
            pair[keyPath: side] = chosen
            library.setLanguages(entry.id, pair)
        })
    }

    /// How the dictionary's entries look: XDict's reading style, or the dictionary's own.
    private var reading: some View {
        Section("Reading") {
            Toggle(isOn: $originalStyle) {
                Text("Original style")
                Text("Show this dictionary's entries as its own stylesheets draw them, instead of in XDict's reading style. Links and protections are the same either way.")
            }
            .accessibilityLabel(Text("Original style"))
            .accessibilityIdentifier("original-style")
            readingStyle
        }
    }

    /// The edition's first 12 hexadecimal characters.
    static func short(_ edition: Edition) -> String {
        String(edition.rawValue.split(separator: ":").last.map { $0.prefix(12) } ?? "")
    }

    private var about: some View {
        Section("About") {
            if let info = entry.info {
                LabeledContent {
                    Text(verbatim: HeaderText.plain(info.title)).textSelection(.enabled)
                } label: {
                    Text("Title")
                }
                let description = HeaderText.plain(info.description)
                if !description.isEmpty {
                    LabeledContent {
                        Text(verbatim: description).textSelection(.enabled)
                    } label: {
                        Text("Description")
                    }
                }
                LabeledContent {
                    Text("MDict \(info.formatVersion)")
                } label: {
                    Text("Format")
                }
                LabeledContent {
                    Text(info.keys, format: .number)
                } label: {
                    Text("Entries")
                }
            } else {
                Text("Known once the dictionary is imported.").foregroundStyle(.secondary)
            }
            // Short, the whole value in its help and on the pasteboard (UI review L-11).
            if let edition = entry.edition {
                LabeledContent {
                    HStack(spacing: Tokens.Space.s) {
                        Text(verbatim: Self.short(edition)).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                            .help(Text(verbatim: edition.rawValue))
                        Button {  // placement: glyph
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(edition.rawValue, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Copy"))
                        .accessibilityLabel(Text("Copy"))
                    }
                } label: {
                    Text("Edition")
                }
            }
        }
    }
}

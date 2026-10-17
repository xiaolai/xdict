import SwiftUI
import XDictContract
import XDictEntryView
import XDictLibrary

/// **One dictionary's details**: the question a changed file asks (and the undo of its answer), the reader's name for
/// it, its languages (asked when the file name did not state them, L3), its About from the header (R11: title,
/// description, format, entries, edition), what the reader should know about its files, the files themselves, and
/// Remove.
struct LibraryDetail: View {
    let library: Library
    let entry: LibraryEntry
    /// ADR-0010 Q3: this dictionary in its own style, kept under its lineage (never its path), off by default.
    @AppStorage private var originalStyle: Bool

    init(library: Library, entry: LibraryEntry) {
        self.library = library
        self.entry = entry
        _originalStyle = AppStorage(wrappedValue: false, EntryPreferences.originalStyleKey(entry.preferencesKey))
    }

    /// The languages the reader is offered: XDict's own two, and those dictionaries most often pair them with. Named by
    /// the system in the reader's language.
    static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "la", "ar"]

    var body: some View {
        Form {
            if let offer = entry.offer { joinQuestion(offer) }
            if entry.join != nil { joined }
            Section {
                TextField(text: Binding(get: { entry.readersName ?? "" }, set: { library.rename(entry.id, $0) }),
                          prompt: Text(verbatim: DisplayName.of(readers: nil, title: entry.info?.title ?? "",
                                                                fileName: entry.mdx?.fileName ?? ""))) {
                    Text("Name")
                }
            }
            languages
            reading
            about
            health
            readingStyle
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
            Section {
                Button("Remove from Library", role: .destructive) {
                    Task { await library.remove(entry.id) }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// What the reading style does to this dictionary (ADR-0010, owner's decision of 2026-10-17): asked of the service
    /// when these details show. The dictionary's own words (families, selectors, sheet paths) are shown as written.
    @ViewBuilder private var readingStyle: some View {
        Section("Reading style") {
            if let state = library.readingStyles[entry.id] {
                Text(LibrarySentences.styleStatus(state)).textSelection(.enabled)
                if case .read(let style) = state {
                    Text(LibrarySentences.baseSize(px: style.basePx, from: style.baseFrom)).textSelection(.enabled)
                    if !style.fonts.isEmpty {
                        DisclosureGroup {
                            ForEach(Array(style.fonts.enumerated()), id: \.offset) { _, font in
                                VStack(alignment: .leading, spacing: 2) {
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
                            Text(verbatim: skipped).font(.caption.monospaced()).foregroundStyle(.secondary)
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
        }
        .task(id: entry.id) { await library.loadReadingStyle(entry.id) }
    }

    /// What the health check found (WI-12): where it is, then one sentence per finding, each opening to its places.
    @ViewBuilder private var health: some View {
        if let state = library.health[entry.id] {
            Section("Health") {
                Text(LibrarySentences.healthStatus(state)).textSelection(.enabled)
                if case .checked(let report) = state {
                    ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
                        if finding.examples.isEmpty {
                            Text(LibrarySentences.health(finding)).textSelection(.enabled)
                        } else {
                            DisclosureGroup {
                                ForEach(Array(finding.examples.enumerated()), id: \.offset) { _, example in
                                    VStack(alignment: .leading, spacing: 2) {
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
            Text("The file of this dictionary changed. Is it still the same dictionary?")
            Text("""
                If it is, what you keep about it carries over. If not, it becomes a dictionary of its own. You can \
                change your mind afterwards.
                """)
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Same Dictionary") { Task { _ = await library.acceptJoin(entry.id) } }
                    .keyboardShortcut(.defaultAction)
                Button("A Different Dictionary") { library.declineJoin(entry.id) }
            }
        }
    }

    private var joined: some View {
        Section {
            HStack {
                Text("Kept as the same dictionary as the file it replaced.")
                Spacer()
                Button("Undo") { Task { _ = await library.undoJoin(entry.id) } }
            }
        }
    }

    private var languages: some View {
        Section("Languages") {
            if entry.languages.needsAsking {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.languages.basis == .unknown
                         ? LocalizedStringResource("XDict could not tell this dictionary's languages from its file name. Which are they?")
                         : LocalizedStringResource("XDict guessed these languages from the file name. Are they right?"))
                    Button("They Are Right") { library.confirmLanguages(entry.id) }
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
            .accessibilityIdentifier("original-style")
        }
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
            if let edition = entry.edition {
                LabeledContent {
                    Text(verbatim: edition.rawValue).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                } label: {
                    Text("Edition")
                }
            }
        }
    }
}

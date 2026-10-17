import SwiftUI
import UniformTypeIdentifiers
import XDictLibrary

/// **The library window** (plan-macos-v1 WI-5): the reader's dictionaries in their order, each with whether it answers
/// lookups and where it is (importing with progress and Cancel, ready, or refused with its reason and Retry); Add
/// Dictionaries… (⌘O, files or folders) and drag and drop anywhere in the window; the selected one's details beside the
/// list. Plain macOS: a sidebar list with a toolbar, a grouped form for the details, everything reachable from the
/// keyboard (arrows select, ⌥⌘↑ and ⌥⌘↓ move, Delete removes, Space toggles the checkbox).
public struct LibraryView: View {
    @Bindable private var library: Library
    @State private var selection: UUID?
    @State private var choosing = false
    @State private var dropping = false

    private let layout: Layout

    /// Where the list is shown. **The window** is a split view with its own toolbar. **Settings** has a toolbar of its
    /// own, its tabs: a split view there would put a sidebar toggle and these buttons beside the tabs and rename the
    /// window, so Settings gets a list with the + − ↑ ↓ bar under it and the details beside it, as macOS's own Settings
    /// panes do (owner, 2026-10-17).
    public enum Layout: Sendable { case window, settings }

    public init(library: Library, layout: Layout = .window) {
        self.library = library
        self.layout = layout
    }

    /// What Add Dictionaries… offers: folders, and MDict's two kinds of file (typed by extension, since no app
    /// registers them).
    static let chooseable: [UTType] = [.folder] + ["mdx", "mdd"].compactMap { UTType(filenameExtension: $0) }

    public var body: some View {
        arranged
        .fileImporter(isPresented: $choosing, allowedContentTypes: Self.chooseable, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { selectFirst(of: library.add(urls)) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            selectFirst(of: library.add(fileURLs))
            return !fileURLs.isEmpty
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).padding(4)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
    }

    @ViewBuilder private var arranged: some View {
        switch layout {
        case .window:
            NavigationSplitView {
                list
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            } detail: {
                detail
            }
            .navigationTitle(Text("Library"))
            .toolbar {
                ToolbarItemGroup {
                    Button { choosing = true } label: { Label("Add Dictionaries…", systemImage: "plus") }
                        .keyboardShortcut("o")
                        .help(Text("Add MDict files (.mdx, .mdd) or a folder of them"))
                    Button { selection.map(library.moveUp) } label: { Label("Move Up", systemImage: "arrow.up") }
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                        .disabled(!canMoveUp)
                    Button { selection.map(library.moveDown) } label: { Label("Move Down", systemImage: "arrow.down") }
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                        .disabled(!canMoveDown)
                }
            }
        case .settings:
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    list
                    Divider()
                    listBar
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let entry = library.entries.first(where: { $0.id == id }) {
            LibraryDetail(library: library, entry: entry)
                .id(entry.preferencesKey)
        } else {
            Text("Select a dictionary to see its details.")
                .foregroundStyle(.secondary)
        }
    }

    private var canMoveUp: Bool { selection != nil && library.entries.first?.id != selection }
    private var canMoveDown: Bool { selection != nil && library.entries.last?.id != selection }

    /// The bar under a Settings list: add, remove, and the order, icons with their names as tooltips and for VoiceOver.
    private var listBar: some View {
        HStack(spacing: 0) {
            barButton("Add Dictionaries…", symbol: "plus") { choosing = true }
                .keyboardShortcut("o")
            barButton("Remove", symbol: "minus") { removeSelected() }
                .disabled(selection == nil)
            Divider().frame(height: 16).padding(.horizontal, 4)
            barButton("Move Up", symbol: "arrow.up") { selection.map(library.moveUp) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!canMoveUp)
            barButton("Move Down", symbol: "arrow.down") { selection.map(library.moveDown) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!canMoveDown)
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .frame(height: 28)
    }

    private func barButton(_ name: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .help(Text(name))
        .accessibilityLabel(Text(name))
    }

    private func removeSelected() {
        guard let id = selection else { return }
        selection = nil
        Task { await library.remove(id) }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(library.entries) { entry in
                LibraryRow(library: library, entry: entry, phase: library.phases[entry.id])
                    .tag(entry.id)
            }
            .onMove { library.move(fromOffsets: $0, toOffset: $1) }
        }
        .onDeleteCommand { removeSelected() }
        .overlay {
            if library.entries.isEmpty, library.unreadable == nil {
                ContentUnavailableView {
                    Label("No Dictionaries Yet", systemImage: "books.vertical")
                } description: {
                    Text("""
                        XDict reads the MDict dictionaries you already have: .mdx files, with their .mdd resources. \
                        Add files or a folder, or drop them here.
                        """)
                } actions: {
                    Button("Add Dictionaries…") { choosing = true }
                }
            }
        }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if let unreadable = library.unreadable {
                Banner(text: LibrarySentences.unreadable(unreadable), symbol: "exclamationmark.triangle", dismiss: nil)
            }
            ForEach(Array(library.notices.enumerated()), id: \.offset) { _, notice in
                Banner(text: LibrarySentences.notice(notice), symbol: "info.circle") { library.dismiss(notice) }
            }
        }
    }

    private func selectFirst(of added: [UUID]) {
        if let first = added.first { selection = first }
    }
}

/// One line the reader should read once.
struct Banner: View {
    let text: LocalizedStringResource
    let symbol: String
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}

/// A dictionary in the list: its checkbox (answers lookups or not), its name, where it is, and what can be done now.
struct LibraryRow: View {
    let library: Library
    let entry: LibraryEntry
    let phase: EntryPhase?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle(isOn: Binding(get: { entry.enabled }, set: { library.setEnabled(entry.id, $0) })) {
                Text("Use in lookups")
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help(Text("Use in lookups"))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.displayName).lineLimit(1)
                status
            }
            Spacer(minLength: 4)
            if entry.languages.needsAsking || entry.offer != nil {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.orange)
                    .help(Text("A question awaits your answer in the details"))
                    .accessibilityLabel(Text("A question awaits your answer in the details"))
            }
            action
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .importing(let done, let total) where total > 0:
            ProgressView(value: Double(done), total: Double(total)) {
                Text(LibrarySentences.phase(.importing(done: done, total: total)))
            }
            .controlSize(.small)
        case .some(let phase):
            Text(LibrarySentences.phase(phase))
                .font(.caption)
                .foregroundStyle(Self.isTrouble(phase) ? Color.orange : Color.secondary)
                .lineLimit(2)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var action: some View {
        switch phase {
        case .waiting, .importing:
            Button("Cancel") { Task { await library.cancelImport(entry.id) } }
                .controlSize(.small)
        case .cancelled, .failed, .refused, .missing, .outsideItsFolder:
            Button("Retry") { library.retry(entry.id) }
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    static func isTrouble(_ phase: EntryPhase) -> Bool {
        switch phase {
        case .refused, .failed, .missing, .outsideItsFolder: true
        case .waiting, .importing, .cancelling, .opening, .ready, .cancelled: false
        }
    }
}

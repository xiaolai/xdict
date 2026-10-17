import AppKit
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
    @State private var showsNotices = false
    @Environment(\.undoManager) private var undoManager
    private let requests = LibraryRequests.shared

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
        // The open panel's button says what happens (UI review L-19).
        .fileDialogConfirmationLabel(Text("Add"))
        // Add Dictionaries… asked from the File menu, the main window or the setup board (A-04, M-10, U-02).
        .onChange(of: requests.importWanted, initial: true) {
            if requests.takeImport() { choosing = true }
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
        .safeAreaInset(edge: .top, spacing: 0) { unreadableBanner }
    }

    @ViewBuilder private var arranged: some View {
        switch layout {
        case .window:
            // Add, remove and the order under the list, as in Settings, not in the toolbar (UI review L-05).
            NavigationSplitView {
                VStack(spacing: 0) {
                    list
                    Divider()
                    listBar
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            } detail: {
                detail
            }
            .navigationTitle(Text("Library"))
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
            LibraryDetail(library: library, entry: entry, remove: { removeSelected() }, locate: { choosing = true })
                .id(entry.preferencesKey)
        } else {
            ContentUnavailableView("No Dictionary Selected", systemImage: "books.vertical")
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

    /// Removes the selected dictionary; Edit ▸ Undo puts it back where it was (UI review L-09).
    private func removeSelected() {
        guard let id = selection else { return }
        selection = nil
        let undo = undoManager
        let library = library
        Task {
            guard let removed = await library.removeForUndo(id) else { return }
            undo?.registerUndo(withTarget: library) { library in
                MainActor.assumeIsolated { library.restore(removed) }
            }
            undo?.setActionName(String(localized: "Remove Dictionary"))
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(library.entries) { entry in
                LibraryRow(library: library, entry: entry, phase: library.phases[entry.id], locate: { choosing = true })
                    .tag(entry.id)
                    .listRowSeparator(.hidden)
            }
            .onMove { library.move(fromOffsets: $0, toOffset: $1) }
        }
        .onDeleteCommand { removeSelected() }
        .safeAreaInset(edge: .bottom, spacing: 0) { noticeBar }
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

    @ViewBuilder private var unreadableBanner: some View {
        if let unreadable = library.unreadable {
            Banner(text: LibrarySentences.unreadable(unreadable), symbol: "exclamationmark.triangle", dismiss: nil)
        }
    }

    /// **What the last addition could not do, as one line under the list** (UI review X7): never over the list or the
    /// empty state; one notice says itself, several are counted, each listed with its reason behind Show Details.
    @ViewBuilder private var noticeBar: some View {
        let notices = library.notices
        if !notices.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                    .fixedSize(horizontal: false, vertical: true)
                    if notices.count > 1 {
                        Button("Show Details…") { showsNotices = true }
                            .controlSize(.small)
                            .popover(isPresented: $showsNotices) { noticeDetails }
                    }
                    Button("Dismiss") { for notice in notices { library.dismiss(notice) } }
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.notices")
        }
    }

    private var noticeDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(library.notices.enumerated()), id: \.offset) { _, notice in
                    Text(LibrarySentences.notice(notice)).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .frame(width: 360)
        .frame(maxHeight: 320)
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
    var locate: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle(isOn: Binding(get: { entry.enabled }, set: { library.setEnabled(entry.id, $0) })) {
                Text("Use in lookups")
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help(Text("Use in lookups"))
            // Not offered where it cannot work (UI review L-08).
            .disabled(phase.map(Self.isTrouble) ?? false)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.displayName).lineLimit(1)
                status
            }
            Spacer(minLength: 4)
            action
            // A fixed slot, so the badge never moves with the row's action (L-07); secondary, since a caution colour on
            // nearly every row stops meaning anything (L-06).
            Group {
                if entry.languages.needsAsking || entry.offer != nil {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .help(Text("A question awaits your answer in the details"))
                        .accessibilityLabel(Text("A question awaits your answer in the details"))
                }
            }
            .frame(width: 16)
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
            if let sentence = ProblemStatus.sentence(for: phase) {
                ProblemStatus(sentence: sentence, compact: true)
            } else {
                Text(LibrarySentences.phase(phase))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .none:
            EmptyView()
        }
    }

    /// The action the row's problem needs (UI review L-04).
    @ViewBuilder private var action: some View {
        if let action = LibraryRowAction.for(phase) {
            Button(action.title) { perform(action) }
                .controlSize(.small)
        }
    }

    private func perform(_ action: LibraryRowAction) {
        switch action {
        case .cancel: Task { await library.cancelImport(entry.id) }
        case .locate: locate()
        case .showInFinder: Self.showInFinder(entry)
        case .tryAgain: library.retry(entry.id)
        }
    }

    static func showInFinder(_ entry: LibraryEntry) {
        guard let path = entry.mdx?.location.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func isTrouble(_ phase: EntryPhase) -> Bool {
        switch phase {
        case .refused, .failed, .missing, .outsideItsFolder: true
        case .waiting, .importing, .cancelling, .opening, .ready, .cancelled: false
        }
    }
}

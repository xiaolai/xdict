import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XDictAppleSource
import XDictContract
import XDictEntryView
import XDictLibrary
import XDictTokens

/// **Settings ▸ Dictionaries, as Apple's Dictionary draws it** (parity ledger P39, P40; owner, 2026-10-17: follow
/// Apple), **and the only dictionary list in the app** (ADR-0012 d.2): Apple's line "Drag reference sources into the
/// order you prefer:", a bordered table with alternating rows — a checkbox, the dictionary's full name and its
/// languages, 20 pt rows — that also takes files and folders dropped from elsewhere; under it Apple's `+`/`−`; under
/// those, in a box, the selected dictionary's options and its one current problem. Import progress with Cancel and the
/// notices sit in a strip above the table; Details… opens today's `LibraryDetail` in a sheet. One presentation at a time
/// (d.3), held by `SettingsRoute`.
public struct SettingsDictionaries: View {
    /// Apple's Settings window: 600 pt wide; its table's rows 20 pt (settings.ax.json, 2026-10-17).
    nonisolated public static let paneWidth: CGFloat = Tokens.Window.settingsWidth
    nonisolated public static let rowHeight: CGFloat = Tokens.Row.settingsTable
    /// d.6: the table at least this tall, scrolling past it.
    nonisolated public static let tableMinHeight: CGFloat = Tokens.Window.settingsTableMin
    /// d.6: the margin kept above and below the window on the screen.
    nonisolated static let screenMargin: CGFloat = Tokens.Inset.settingsScreenMargin

    nonisolated public static let instruction = LocalizedStringResource("Drag reference sources into the order you prefer:")
    nonisolated public static let tableName = LocalizedStringResource("Dictionaries")
    nonisolated public static let noSelection = LocalizedStringResource("Select a dictionary to see its options.")
    nonisolated public static let details = LocalizedStringResource("Details…")
    nonisolated public static let removedNotice = LocalizedStringResource("That dictionary is no longer in your library.")

    /// What Add MDX Files… offers: folders, and MDict's two kinds of file (typed by extension, since no app registers
    /// them).
    nonisolated public static let choosesFolders = true
    nonisolated public static let chooseableExtensions = ["mdx", "mdd"]
    nonisolated static let chooseable: [UTType] =
        (choosesFolders ? [.folder] : []) + chooseableExtensions.compactMap { UTType(filenameExtension: $0) }

    /// The `+` menu's items (d.2), in order.
    public enum AddItem: CaseIterable, Sendable {
        case mdxFiles
        /// ADR-0011: the Apple dictionaries installed on this Mac, converted once (plan WI-5).
        case appleDictionaries

        public var title: LocalizedStringResource {
            switch self {
            case .mdxFiles: "Add MDX Files…"
            case .appleDictionaries: "Add Apple Dictionaries…"
            }
        }

        /// ⌘O, File ▸ Add Dictionaries…'s key, shown on the item it does while the pane is key (d.3).
        public var opensWithCommandO: Bool { self == .mdxFiles }

        var isOffered: Bool {
            switch self {
            case .mdxFiles, .appleDictionaries: true
            }
        }
    }

    /// The `+` menu as offered.
    nonisolated public static var addMenu: [AddItem] { AddItem.allCases.filter(\.isOffered) }

    /// d.6: the pane is never taller than the screen's visible height less a margin above and below, nor shorter than
    /// its table.
    nonisolated public static func maxPaneHeight(visible: CGFloat) -> CGFloat {
        max(visible - 2 * screenMargin, tableMinHeight)
    }

    /// The Details… sheet: the pane's width, and no taller than the pane it covers less a margin above and below, so it
    /// never hangs past the Settings window (tour, light-en, 2026-10-18: window to ~605 pt, sheet to ~800); its form
    /// scrolls inside. Bounded above, and below by a usable minimum that a small pane still holds.
    nonisolated public static let sheetMargin: CGFloat = Tokens.Inset.settingsSheetMargin
    nonisolated public static let detailsSheetMinHeight: CGFloat = Tokens.Window.detailsSheetMin
    nonisolated public static let detailsSheetMaxHeight: CGFloat = Tokens.Window.detailsSheetMax

    nonisolated public static func detailsSheetSize(paneHeight: CGFloat) -> CGSize {
        let fits = paneHeight - 2 * sheetMargin
        let height = paneHeight <= 0 ? detailsSheetMinHeight
            : min(detailsSheetMaxHeight, max(min(detailsSheetMinHeight, paneHeight), fits))
        return CGSize(width: paneWidth, height: height)
    }

    /// Where the drop instrument drags to: the centre of the dictionary table under `root`, in global top-left points;
    /// nil when no table is there (`LibraryDrop`, ADR-0012 d.7).
    public static func dropPoint(in root: NSView) -> CGPoint? {
        guard let frame = DictionaryTable.screenFrame(in: root) else { return nil }
        return DictionaryTable.dropPoint(tableOnScreen: frame, mainScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    // MARK: - ADR-0013 d.6: display options

    /// **The options the selected dictionary offers**: those its current edition declares, as the service answered, in
    /// the catalogue's shape and with a name the shell can say. None while the answer is unknown, failed or of another
    /// edition, so no row shows unless the edition declares an option.
    nonisolated public static func displayOptionRows(_ state: DisplayOptionsState?, edition: Edition?) -> [DisplayOption] {
        guard case .read(let declared, let of) = state, let edition, of == edition else { return [] }
        return declared.options.filter { option in
            EntryDisplayOption(option) != nil && optionTitle(option.id) != nil
                && option.values.allSatisfy { optionValue(option.id, $0) != nil }
        }
    }

    /// An option's name, by its catalogue id; nil for one this version cannot name.
    nonisolated public static func optionTitle(_ id: String) -> LocalizedStringResource? {
        switch id {
        case "pronunciation": LocalizedStringResource("Pronunciation")
        default: nil
        }
    }

    /// A value's name, by its option's catalogue id; nil for one this version cannot name.
    nonisolated public static func optionValue(_ id: String, _ value: String) -> LocalizedStringResource? {
        switch (id, value) {
        case ("pronunciation", "respell"): LocalizedStringResource("Respelling")
        case ("pronunciation", "ipa"): LocalizedStringResource("IPA")
        case ("pronunciation", "both"): LocalizedStringResource("Both")
        default: nil
        }
    }

    /// The dictionaries under way, in the library's order: what the strip shows (no "Ready": the call of 2026-10-18).
    nonisolated public static func underWay(order: [UUID], phases: [UUID: EntryPhase]) -> [UUID] {
        order.filter { id in
            switch phases[id] {
            case .waiting, .importing, .cancelling, .opening: true
            default: false
            }
        }
    }

    @Bindable private var library: Library
    @Bindable private var route: SettingsRoute
    private let appleImport: AppleImportHost?
    @State private var selection: UUID?
    @State private var paneHeight: CGFloat = 0
    @Environment(\.undoManager) private var undoManager

    public init(library: Library, route: SettingsRoute = .shared, appleImport: AppleImportHost? = nil) {
        self.library = library
        self.route = route
        self.appleImport = appleImport
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            SettingsLibraryStrip(library: library, route: route)
            Text(Self.instruction)
            table
                .frame(minHeight: Self.tableMinHeight)
                .overlay { emptyState }
            SettingsAddRemoveBar(canAdd: library.unreadable == nil, canRemove: selection != nil,
                                 add: { item in add(item) }, remove: { removeSelected() })
            options
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.vertical, Tokens.Space.l)
        .frame(width: Self.paneWidth)
        .frame(maxHeight: Self.maxPaneHeight(visible: NSScreen.main?.visibleFrame.height ?? Tokens.Window.fallbackScreenHeight))
        // The Details… sheet is sized from this, so it fits inside the window.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
        .onAppear { resolveRoute() }
        // ADR-0011 decision 7: each Apple dictionary compared with its installed bundle when Settings opens.
        .task { await checkAppleDictionaries() }
        .onChange(of: route.pendingSelection) { resolveRoute() }
        .onChange(of: library.entries.map(\.id)) { resolveRoute() }
        .fileImporter(isPresented: presented(.importer), allowedContentTypes: Self.chooseable,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { selectFirst(of: library.add(urls)) }
        }
        // The open panel's button says what happens (UI review L-19).
        .fileDialogConfirmationLabel(Text("Add"))
        .sheet(isPresented: detailsShown) { detailsSheet }
        .sheet(isPresented: presented(.appleImport), onDismiss: { appleImport?.importer.clearFinished() }) {
            if let appleImport {
                AppleImportSheet(library: library, host: appleImport, size: Self.detailsSheetSize(paneHeight: paneHeight),
                                 done: { route.dismiss(.appleImport) })
            }
        }
    }

    // MARK: - The table

    /// An AppKit table, as Apple's is: SwiftUI's `Table` is an outline to Accessibility and its rows are 24 pt
    /// (the tour's capture of 2026-10-17), where Apple's are an AXTable's, 20 pt.
    private var table: some View {
        let rows = library.entries.map { entry in
            DictionaryTable.Row(id: entry.id, name: entry.displayName,
                                language: Self.language(entry.languages.pair, in: .current), enabled: entry.enabled,
                                // Not offered where it cannot work (UI review L-08).
                                usable: !(library.phases[entry.id].map(LibraryRowAction.isTrouble) ?? false))
        }
        return DictionaryTable(
            rows: rows, selection: $selection,
            name: String(localized: Self.tableName), checkboxName: String(localized: "Use in lookups"),
            setEnabled: { library.setEnabled($0, $1) },
            move: { dragged, index in
                if let move = Self.move(dragged: dragged, to: index, in: library.entries.map(\.id)) {
                    library.move(fromOffsets: move.offsets, toOffset: move.destination)
                }
            },
            importFiles: library.unreadable == nil ? { urls in selectFirst(of: library.add(urls)) } : nil,
            key: { action, id in key(action, id) })
    }

    private func key(_ action: DictionaryTable.KeyAction, _ id: UUID) {
        switch action {
        case .remove: removeSelected()
        case .moveUp: library.moveUp(id)
        case .moveDown: library.moveDown(id)
        case .toggle:
            guard let entry = library.entries.first(where: { $0.id == id }),
                  !(library.phases[id].map(LibraryRowAction.isTrouble) ?? false) else { return }
            library.setEnabled(id, !entry.enabled)
        }
    }

    /// No dictionaries yet: what XDict reads, and the way to add some (hidden while the library is unreadable, whose
    /// sentence the strip says instead).
    @ViewBuilder private var emptyState: some View {
        if library.entries.isEmpty, library.unreadable == nil {
            VStack(spacing: Tokens.Space.sm) {
                Text("No Dictionaries Yet").font(.headline)
                Text("""
                    XDict reads the MDict dictionaries you already have: .mdx files, with their .mdd resources. \
                    Add files or a folder, or drop them here.
                    """)
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { add(.mdxFiles) } label: { Text(AddItem.mdxFiles.title) }
            }
            .padding(Tokens.Space.xxl)
        }
    }

    // MARK: - Beneath the table

    /// The box under the bar: the selected dictionary's options and its one current problem, as Apple's slot shows a
    /// dictionary's own; it grows with what it holds (d.6).
    private var options: some View {
        Group {
            if let id = selection, let entry = library.entries.first(where: { $0.id == id }) {
                SettingsDictionaryOptions(library: library, entry: entry,
                                          details: { route.request(.details(entry.id)) },
                                          locate: { route.request(.importer) },
                                          convertAgain: appleImport.map { host in { convertAgain(entry.id, host) } },
                                          conversion: conversionLine(for: entry),
                                          cancelConversion: cancelConversion(for: entry))
                    .id(entry.preferencesKey)
            } else {
                Text(Self.noSelection).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.sm)
        .frame(maxWidth: .infinity, minHeight: Tokens.Row.optionsBoxMin, alignment: .leading)
        .overlay { Rectangle().strokeBorder(.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.dictionaryOptions")
    }

    // MARK: - Presentations

    private func presented(_ which: SettingsPresentation) -> Binding<Bool> {
        Binding(get: { route.presentation == which }, set: { shown in if !shown { route.dismiss(which) } })
    }

    private var detailsShown: Binding<Bool> {
        Binding(get: { if case .details = route.presentation { true } else { false } },
                set: { shown in if !shown, case .details = route.presentation { route.dismiss() } })
    }

    @ViewBuilder private var detailsSheet: some View {
        if case .details(let id) = route.presentation, let entry = library.entries.first(where: { $0.id == id }) {
            let size = Self.detailsSheetSize(paneHeight: paneHeight)
            VStack(spacing: 0) {
                LibraryDetail(library: library, entry: entry,
                              remove: { route.dismiss(); remove(id) }, locate: { route.locate() })
                    .id(entry.preferencesKey)
                Divider()
                HStack {
                    Spacer()
                    Button { route.dismiss() } label: { Text("Done") }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(Tokens.Space.m)
            }
            // The form scrolls inside; the sheet never extends past the window (`detailsSheetSize`).
            .frame(width: size.width, height: size.height)
        }
    }

    private func add(_ item: AddItem) {
        switch item {
        case .mdxFiles: route.request(.importer)
        case .appleDictionaries: if appleImport != nil { route.request(.appleImport) }
        }
    }

    // MARK: - Apple dictionaries (ADR-0011)

    private func checkAppleDictionaries() async {
        guard let appleImport, !library.importedAppleBundles.isEmpty else { return }
        await appleImport.importer.checkForUpdates(installed: await appleImport.find())
    }

    /// What the importer is doing for this dictionary's bundle, for the box (the sheet is closed, so nothing else says).
    private func conversionLine(for entry: LibraryEntry) -> AppleConversionLine? {
        guard let identifier = entry.appleSource?.bundleIdentifier else { return nil }
        return AppleConversionLine.of(appleImport?.importer.steps[identifier])
    }

    private func cancelConversion(for entry: LibraryEntry) -> (() -> Void)? {
        guard let host = appleImport, let identifier = entry.appleSource?.bundleIdentifier else { return nil }
        return { Task { await host.importer.cancel(identifier) } }
    }

    /// Convert Again from the bundle as installed now; gone meanwhile, the row says so at the next check.
    private func convertAgain(_ id: UUID, _ host: AppleImportHost) {
        guard let identifier = library.entries.first(where: { $0.id == id })?.appleSource?.bundleIdentifier else { return }
        Task {
            let installed = await host.find()
            if let bundle = installed.first(where: { $0.identifier == identifier }), bundle.refusal == nil {
                host.importer.convertAgain(id, from: bundle)
            } else {
                await host.importer.checkForUpdates(installed: installed)
            }
        }
    }

    // MARK: - Selection and removal

    private func resolveRoute() {
        switch route.resolveSelection(among: library.entries.map(\.id)) {
        case .unchanged: break
        case .select(let id): selection = id
        case .removed: selection = nil
        }
    }

    private func selectFirst(of added: [UUID]) {
        if let first = added.first { selection = first }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        remove(id)
    }

    /// Removes a dictionary, no confirmation; Edit ▸ Undo puts it back where it was (UI review L-09, ADR-0012 d.2).
    private func remove(_ id: UUID) {
        if selection == id { selection = nil }
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

    // MARK: - Pure helpers

    /// The language column: one language once, two as "search-explanation", empty when neither is known.
    nonisolated public static func language(_ pair: LanguagePair, in locale: Locale) -> String {
        let names = [pair.search, pair.explanation].compactMap { $0 }
            .map { locale.localizedString(forIdentifier: $0) ?? $0 }
        guard let first = names.first else { return "" }
        return names.dropFirst().allSatisfy { $0 == first } ? first : names.joined(separator: "-")
    }

    /// Rows dragged (as their ids) onto `index`, in the library's own terms; nil when none of them is in the list.
    nonisolated public static func move(dragged: [String], to index: Int, in ids: [UUID])
        -> (offsets: IndexSet, destination: Int)? {
        let offsets = IndexSet(dragged.compactMap(UUID.init(uuidString:)).compactMap { ids.firstIndex(of: $0) })
        return offsets.isEmpty ? nil : (offsets, index)
    }
}

extension EntryDisplayOption {
    /// The contract's option in the entry view's terms: nil unless it has the catalogue's shape.
    init?(_ option: DisplayOption) {
        self.init(id: option.id, attribute: option.attribute, values: option.values, defaultValue: option.defaultValue)
    }
}

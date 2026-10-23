import SwiftUI
import XDictAppleSource
import XDictLibrary
import XDictTokens

/// What Settings needs to offer Add Apple Dictionaries… and Convert Again (ADR-0011): the importer, how the installed
/// bundles are found (the AssetsV2 path for the reader; a folder of an instrument's own under one), what Dictionary.app
/// knows is available (plan-setup-v2 WI-3), and how to open Dictionary.app to download one.
public struct AppleImportHost: Sendable {
    public let importer: AppleImporter
    public let discover: @Sendable () -> [InstalledBundle]
    /// **What Dictionary.app last knew was available on this Mac**, less what is installed; nil when the preference
    /// could not be read. It takes the installed bundles, so one scan walks the AssetsV2 tree once. Read-only: nothing
    /// here can start the download, and no MobileAsset API is public.
    public let available: @Sendable ([InstalledBundle]) -> [AvailableBundle]?
    /// **What is installed, by name, without reading any of it**: the cheap half of a scan, for the poll.
    public let listing: @Sendable () -> Set<String>
    /// Dictionary.app's own list as read (not yet compared with what is installed): one preference, for the poll — so a
    /// list that appears, changes or becomes readable is noticed without a full scan.
    public let availableEntries: @Sendable () -> [String]?
    /// Opens Dictionary.app, the only thing that can download one (plan-setup-v2 WI-3).
    public let openDictionary: @MainActor () -> Void

    public init(importer: AppleImporter, discover: @escaping @Sendable () -> [InstalledBundle],
                available: @escaping @Sendable ([InstalledBundle]) -> [AvailableBundle]? = { _ in nil },
                listing: @escaping @Sendable () -> Set<String> = { [] },
                availableEntries: @escaping @Sendable () -> [String]? = { nil },
                openDictionary: @escaping @MainActor () -> Void = { SetupActions.system.openDictionary() }) {
        self.importer = importer
        self.discover = discover
        self.available = available
        self.listing = listing
        self.availableEntries = availableEntries
        self.openDictionary = openDictionary
    }

    /// What one scan finds.
    public struct Scan: Sendable, Equatable {
        public let bundles: [InstalledBundle]
        public let available: [AvailableBundle]?

        public init(bundles: [InstalledBundle], available: [AvailableBundle]?) {
            self.bundles = bundles
            self.available = available
        }
    }

    /// Both lists, off the main actor: each installed bundle is walked for its size.
    public func scan() async -> Scan {
        let discover = discover
        let available = available
        return await Task.detached(priority: .userInitiated) {
            let bundles = discover()
            return Scan(bundles: bundles, available: available(bundles))
        }.value
    }

    /// The installed folders' paths, off the main actor: two directory listings, no property list and no file size.
    public func installedNames() async -> Set<String> {
        let listing = listing
        return await Task.detached(priority: .utility) { listing() }.value
    }

    /// Dictionary.app's own list, off the main actor: one preference read, nothing walked.
    public func dictionaryAppList() async -> [String]? {
        let read = availableEntries
        return await Task.detached(priority: .utility) { read() }.value
    }

    /// The installed bundles found, off the main actor.
    public func find() async -> [InstalledBundle] {
        await scan().bundles
    }
}

/// **Add Apple Dictionaries…** (ADR-0011 decision 1; plan WI-5; the second section by plan-setup-v2 WI-3), a sheet over
/// Settings ▸ Dictionaries shown through `SettingsRoute`'s one presentation (ADR-0012 d.3): a checkbox per installed
/// bundle with its languages and size; "Already imported" for one the library has; one XDict will not convert greyed with
/// its sentence; **what Dictionary.app knows and this Mac has not downloaded**, each sent to Dictionary.app, which is the
/// only thing that can download it; Import and Cancel; each import's progress with its own Cancel. The list is rescanned
/// every two seconds while the sheet is up, so a download finished in Dictionary.app moves its row into the first
/// section without closing anything. `AppleImportChoice` is its logic.
struct AppleImportSheet: View {
    let library: Library
    let host: AppleImportHost
    let size: CGSize
    let done: () -> Void
    @State private var choice = AppleImportChoice()
    @State private var found = false
    /// **What the reader typed to narrow the list** (owner, 2026-10-23): kept while the sheet is up, cleared with it.
    @State private var filter = ""
    /// **One scan at a time**: Rescan pressed while the poll's scan is running asks for one more after it, rather than
    /// starting a second walk whose older answer could land last (audit-fix 2026-10-22).
    @State private var isScanning = false
    @State private var scanAgain = false
    /// Bumped by Rescan; `.task(id:)` owns the scan, so closing the sheet cancels it with the view (audit-fix 2026-10-22).
    @State private var rescanCount = 0
    /// The Rescan this sheet has scanned for. A press that arrives while a scan runs cancels that scan and starts
    /// another; if the cancelled one unwound first, the poll below sees the count and scans within its interval — so a
    /// press is never lost, only ever a moment late.
    @State private var scannedRescanCount = 0
    /// The folders and the Dictionary.app list last scanned: the poll compares both and pays for a scan only when one
    /// of them changed.
    @State private var installedNames: Set<String> = []
    @State private var dictionaryAppList: [String]?

    private var importer: AppleImporter { host.importer }

    /// How often the two lists are read again while the sheet is up (plan-setup-v2 WI-3): a directory listing and one
    /// preference read, which is what lets a finished download move its row without a relaunch.
    static let rescanInterval: Duration = .seconds(2)

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            Text(AppleImportSentences.title).font(.headline)
            Text(AppleImportSentences.intro).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            filterField
            list
            availableFooter
            // R3: Cancel (Done once imports have started) left of Import, the default action.
            SheetFooter([
                FooterAction(.cancel, title: Text(importer.steps.isEmpty ? "Cancel" : "Done"),
                             identifier: "appleImport.close", perform: done),
                FooterAction(.primary, title: Text(AppleImportSentences.importButton), identifier: "appleImport.import",
                             isDisabled: choice.toImport(steps: importer.steps).isEmpty, perform: startImport),
            ])
        }
        .padding(Tokens.Space.l)
        .frame(width: size.width, height: size.height)
        // The first scan, and every Rescan, through one view-scoped task; the poll runs in its own.
        .task(id: rescanCount) { await refresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.rescanInterval)
                guard !Task.isCancelled else { break }
                await poll()
            }
        }
        .onChange(of: library.importedAppleBundles) {
            choice.update(bundles: choice.bundles, imported: library.importedAppleBundles, available: choice.available)
        }
        // **`contain`, then the sheet's own name** (measured on macOS 27.0.1, 2026-10-22: with the identifier alone, the
        // four footer buttons all reported `appleImport.sheet` instead of their own names, so no reader — and no E2E
        // stage — could reach Import, Cancel or Rescan). A container identifier must not take its children's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appleImport.sheet")
    }

    @ViewBuilder private var list: some View {
        if !found {
            HStack(spacing: Tokens.Space.sm) {
                ProgressView().controlSize(.small)  // placement: spinner
                Text(AppleImportSentences.finding).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if choice.bundles.isEmpty, choice.available?.isEmpty != false {
            Text(AppleImportSentences.none).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // The filter narrows both sections; when it keeps nothing, the sheet says so rather than drawing an empty
            // list, and a filter of spaces is no filter at all (`AppleImportChoice.matching`).
            let installed = choice.matching(choice.installedRows(steps: importer.steps), filter)
            let available = choice.matching(choice.availableRows(), filter)
            if installed.isEmpty, available.isEmpty, !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(AppleImportSentences.noMatches).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !installed.isEmpty {
                        Section {
                            ForEach(installed) { row in
                                AppleImportRowView(row: row, toggle: { choice.toggle(row.id, steps: importer.steps) },
                                                   cancel: { Task { await importer.cancel(row.id) } })
                            }
                        }
                    }
                    // Only when there is something to list: an empty "Available" section would look like a failure.
                    if !available.isEmpty {
                        Section {
                            ForEach(available) { row in
                                AppleImportAvailableRowView(row: row, download: openDictionary)
                            }
                        } header: {
                            Text(AppleImportSentences.availableSection)
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .accessibilityIdentifier("appleImport.list")
            }
        }
    }

    /// **The list's filter** (owner, 2026-10-23): a name or a language, matched as it is typed; it narrows the rows and
    /// changes nothing else about them.
    private var filterField: some View {
        TextField(AppleImportSentences.filterPrompt, text: $filter)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("appleImport.filter")
    }

    /// The note under the list and **Rescan**; or, when Dictionary.app's list could not be read at all, the sentence
    /// that says so and the one button that still helps (plan-setup-v2 WI-3 item 4).
    @ViewBuilder private var availableFooter: some View {
        if choice.available == nil, found {
            ActionRow {
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text(AppleImportSentences.availableUnreadable).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AppleImportSentences.howToDownload).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } actions: {
                rescanButton
                Button(action: openDictionary) { Text(AppleImportSentences.openDictionary) }
                    .accessibilityIdentifier("appleImport.dictionaryApp")
            }
        } else {
            ActionRow {
                Text(AppleImportSentences.availableNote).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } actions: {
                rescanButton
            }
        }
    }

    /// **Rescan, said once** for both footers: it asks the view-scoped task above to scan again. The button goes
    /// through `TrailingActions` because a helper is judged where it writes its buttons (ActionLayout's R1–R5):
    /// a button written in a computed view and used in another block's action slot is otherwise an unplaced one.
    private var rescanButton: some View {
        TrailingActions(.pane) {
            Button { rescanCount += 1 } label: { Text(AppleImportSentences.rescan) }
                .accessibilityIdentifier("appleImport.rescan")
        }
    }

    private func openDictionary() {
        host.openDictionary()
    }

    /// **The poll asks for the cheap half first**: two directory listings tell whether anything came or went, and the
    /// walk over every bundle (its property list and its files' sizes) runs only when the answer changed.
    private func poll() async {
        let names = await host.installedNames()
        let list = await host.dictionaryAppList()
        guard names != installedNames || list != dictionaryAppList || rescanCount != scannedRescanCount else { return }
        await refresh()
    }

    private func refresh() async {
        guard !isScanning else {
            scanAgain = true
            return
        }
        isScanning = true
        defer { isScanning = false }
        repeat {
            scanAgain = false
            // **Both cheap reads happen before the walk, and the same values are recorded after it**: recording a
            // later read than the one shown would hide a change from every following poll (audit-fix 2026-10-22).
            let names = await host.installedNames()
            let list = await host.dictionaryAppList()
            let scan = await host.scan()
            // The sheet closed while the walk ran: its answer is not published.
            if Task.isCancelled { return }
            installedNames = names
            dictionaryAppList = list
            choice.update(bundles: scan.bundles, imported: library.importedAppleBundles, available: scan.available)
            found = true
            scannedRescanCount = rescanCount
        } while scanAgain
    }

    private func startImport() {
        let chosen = choice.toImport(steps: importer.steps)
        importer.importBundles(chosen)
        choice.started(chosen.map(\.identifier))
    }
}

/// One installed bundle: its checkbox, name, languages and size, and what became of it.
struct AppleImportRowView: View {
    let row: AppleImportChoice.Row
    let toggle: () -> Void
    let cancel: () -> Void

    var body: some View {
        // A row of the sheet's list (R2): the bundle and what became of it lead, Cancel small at the trailing edge.
        ActionRow(.strip) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.sm) {
                Toggle(isOn: Binding(get: { row.isChosen }, set: { _ in toggle() })) {
                    VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                        Text(verbatim: row.name)
                        HStack(spacing: Tokens.Space.sm) {
                            if !row.language.isEmpty { Text(verbatim: row.language) }
                            Text(verbatim: AppleImportSentences.size(row.bytes))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        ProgressBarView(bar: bar)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!row.isChooseable)
                .frame(maxWidth: .infinity, alignment: .leading)
                status
            }
        } actions: {
            if case .available = row.availability, row.canCancel {
                Button { cancel() } label: { Text("Cancel") }
                    .accessibilityIdentifier("appleImport.cancel.\(row.id)")
            }
        }
        .foregroundStyle(isRefused ? .secondary : .primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appleImport.row.\(row.id)")
    }

    private var isRefused: Bool {
        if case .refused = row.availability { true } else { false }
    }

    /// How far its import is: a count while converting, a moving bar while copying or waiting.
    private var bar: ProgressBar {
        if case .converting(let done, let total) = row.step { return ProgressBar.of(done: done, total: total) }
        return row.step == .copying || row.step == .waiting ? .indeterminate : .none
    }

    @ViewBuilder private var status: some View {
        switch row.availability {
        case .alreadyImported:
            Text(AppleImportSentences.alreadyImported).foregroundStyle(.secondary)
        case .refused(let refusal):
            Text(AppleImportSentences.refusal(refusal)).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        case .available:
            if let sentence = AppleImportSentences.step(row.step) {
                Text(sentence).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        case .notInstalled:
            // Never in this section: a bundle this Mac has not downloaded is not one it can convert yet.
            EmptyView()
        }
    }
}

/// **One dictionary Dictionary.app knows and this Mac has not downloaded** (plan-setup-v2 WI-3): its name, that it is
/// not installed, and the one action that can help — Dictionary.app, where macOS downloads it. No checkbox: XDict has
/// nothing to convert until the download finishes, and after the next rescan the row moves up.
struct AppleImportAvailableRowView: View {
    let row: AppleImportChoice.Row
    let download: () -> Void

    var body: some View {
        ActionRow(.strip) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(verbatim: row.name)
                Text(AppleImportSentences.notInstalled).font(.caption).foregroundStyle(.secondary)
            }
        } actions: {
            Button(action: download) { Text(AppleImportSentences.download) }
                .accessibilityIdentifier("appleImport.download.\(row.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appleImport.available.\(row.name)")
    }
}

import SwiftUI
import XDictAppleSource
import XDictLibrary
import XDictTokens

/// What Settings needs to offer Add Apple Dictionaries… and Convert Again (ADR-0011): the importer, and how the
/// installed bundles are found (the AssetsV2 path for the reader; a folder of an instrument's own under one).
public struct AppleImportHost: Sendable {
    public let importer: AppleImporter
    public let discover: @Sendable () -> [InstalledBundle]

    public init(importer: AppleImporter, discover: @escaping @Sendable () -> [InstalledBundle]) {
        self.importer = importer
        self.discover = discover
    }

    /// The bundles found, off the main actor: each is walked for its size.
    public func find() async -> [InstalledBundle] {
        let discover = discover
        return await Task.detached(priority: .userInitiated) { discover() }.value
    }
}

/// **Add Apple Dictionaries…** (ADR-0011 decision 1; plan WI-5), a sheet over Settings ▸ Dictionaries shown through
/// `SettingsRoute`'s one presentation (ADR-0012 d.3): a checkbox per installed bundle with its languages and size;
/// "Already imported" for one the library has; one XDict will not convert greyed with its sentence; how to download
/// more; Import and Cancel; each import's progress with its own Cancel. `AppleImportChoice` is its logic.
struct AppleImportSheet: View {
    let library: Library
    let host: AppleImportHost
    let size: CGSize
    let done: () -> Void
    @State private var choice = AppleImportChoice()
    @State private var found = false

    private var importer: AppleImporter { host.importer }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            Text(AppleImportSentences.title).font(.headline)
            Text(AppleImportSentences.intro).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            list
            Text(AppleImportSentences.howToDownload).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // R3: Cancel (Done once imports have started) left of Import, the default action.
            SheetFooter(cancel: {
                Button { done() } label: { Text(importer.steps.isEmpty ? "Cancel" : "Done") }
                    .accessibilityIdentifier("appleImport.close")
            }, primary: {
                Button { startImport() } label: { Text(AppleImportSentences.importButton) }
                    .disabled(choice.toImport(steps: importer.steps).isEmpty)
                    .accessibilityIdentifier("appleImport.import")
            })
        }
        .padding(Tokens.Space.l)
        .frame(width: size.width, height: size.height)
        .task { await refresh() }
        .onChange(of: library.importedAppleBundles) {
            choice.update(bundles: choice.bundles, imported: library.importedAppleBundles)
        }
        .accessibilityIdentifier("appleImport.sheet")
    }

    @ViewBuilder private var list: some View {
        if !found {
            HStack(spacing: Tokens.Space.sm) {
                ProgressView().controlSize(.small)  // placement: spinner
                Text(AppleImportSentences.finding).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if choice.bundles.isEmpty {
            Text(AppleImportSentences.none).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(choice.rows(steps: importer.steps)) { row in
                AppleImportRowView(row: row, toggle: { choice.toggle(row.id, steps: importer.steps) },
                                   cancel: { Task { await importer.cancel(row.id) } })
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .accessibilityIdentifier("appleImport.list")
        }
    }

    private func refresh() async {
        let bundles = await host.find()
        choice.update(bundles: bundles, imported: library.importedAppleBundles)
        found = true
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
        }
    }
}

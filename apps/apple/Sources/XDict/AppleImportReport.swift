import Foundation
import XDictAppleSource
import XDictClient
import XDictContract
import XDictInstruments
import XDictLibrary
import XDictUI

/// `XDict --apple-import-report --work <dir>`: the Apple import end to end (ADR-0011, plan WI-5), for the E2E
/// `library.apple` sub-stage (run on the E2E Mac only). A synthetic AssetsV2 tree of the run's own
/// (`SyntheticAppleBundle`; no Apple content) is imported through this bundle's own signed service into the shared
/// app-group container, and each step is checked: the sheet's rows, a refusal's sentence in both languages, a
/// conversion that reads, a cancel that leaves nothing, an update offered, Convert Again joining the lineage, a bundle
/// removed from the Mac whose dictionary still reads, and the launch sweep. Prints one JSON object (`Findings`) and
/// exits 0 when every check passed. Opens no window, and keeps its library in `<work>`, never the reader's.
///
/// The conversion happens in the app group's container, because the service publishes there and nowhere else; what
/// this run makes there it removes again, and it never sweeps a container holding a conversion this run did not make.
enum AppleImportReport {
    static let flag = "--apple-import-report"

    static func run(_ arguments: [String]) -> Never {
        Instrument.report {
            guard let work = Instrument.value(after: "--work", in: arguments).map(URL.init(fileURLWithPath:)) else {
                return Instrument.usage("\(flag) --work <dir>")
            }
            guard let container = SharedContainer.appleImports() else {
                var findings = Findings()
                findings.check("setup", false,
                               "this bundle has no app-group container, so the service cannot convert Apple dictionaries")
                return findings
            }
            return await AppleImportRun(work: work, container: container).runAll()
        }
    }
}

/// What the app-group container held before the run: what it makes there, it removes; what it found, it leaves.
struct ContainerSnapshot {
    let conversions: Set<UUID>
    let staging: Set<String>

    init(root: URL) {
        conversions = Self.conversionFolders(in: root)
        staging = Set((try? FileManager.default.contentsOfDirectory(atPath: SharedContainer.staging(in: root).path)) ?? [])
    }

    /// The `<uuid>` conversion folders of `AppleImports/`, as `AppleImportSweep` names them.
    static func conversionFolders(in root: URL) -> Set<UUID> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).compactMap { name -> UUID? in
            guard let id = UUID(uuidString: name), id.uuidString == name else { return nil }
            return id
        })
    }

    /// Removes every staging folder and conversion folder that appeared after the snapshot.
    func removeWhatIsNew(in root: URL) {
        let fm = FileManager.default
        let stagingRoot = SharedContainer.staging(in: root)
        for name in ((try? fm.contentsOfDirectory(atPath: stagingRoot.path)) ?? []) where !staging.contains(name) {
            try? fm.removeItem(at: stagingRoot.appending(path: name))
        }
        for id in Self.conversionFolders(in: root).subtracting(conversions) {
            try? fm.removeItem(at: root.appending(path: id.uuidString, directoryHint: .isDirectory))
        }
    }
}

/// One run of the Apple import: its tree, its library and its checks, all on the main actor as the app's own are.
@MainActor
final class AppleImportRun {
    /// The checks in the order they run; the stage requires every one by name.
    static let checkNames = [
        "appleImport.listed", "appleImport.refusedShown", "appleImport.converted", "appleImport.reads",
        "appleImport.alreadyImported", "appleImport.cancelLeavesNothing", "appleImport.updateOffered",
        "appleImport.convertAgainJoins", "appleImport.removedStillReads", "appleImport.sweptAtLaunch",
    ]

    static let alpha = "com.example.xdict.e2e.alpha"
    static let big = "com.example.xdict.e2e.big"
    static let refused = "com.example.xdict.e2e.refused"

    let work: URL
    let container: URL
    let before: ContainerSnapshot
    let client: ServiceClient
    let library: Library
    let importer: AppleImporter
    var installed: [InstalledBundle] = []
    var findings = Findings()

    var assets: URL { work.appending(path: "AssetsV2", directoryHint: .isDirectory) }

    init(work: URL, container: URL) {
        let service = ServiceClient()
        let library = Library(
            store: LibraryStore(directory: work.appending(path: "library", directoryHint: .isDirectory)), backend: service)
        self.work = work
        self.container = container
        self.before = ContainerSnapshot(root: container)
        self.client = service
        self.library = library
        self.importer = AppleImporter(library: library, backend: service, root: container)
    }

    func runAll() async -> Findings {
        defer { before.removeWhatIsNew(in: container) }
        do {
            try writeTree()
        } catch {
            findings.check("setup", false, "the synthetic AssetsV2 tree could not be written: \(error)")
            return findings
        }
        await library.start()
        installed = InstalledBundles.discover(root: assets)
        listed()
        refusedShown()
        guard let imported = await converted() else { return findings }
        await reads(imported.dictionary)
        alreadyImported()
        await cancelLeavesNothing()
        guard let revised = await updateOffered(imported.dictionary) else { return findings }
        guard let again = await convertAgainJoins(imported.dictionary, from: revised) else { return findings }
        await removedStillReads(imported.dictionary, bundle: revised)
        sweptAtLaunch(first: imported.record.conversion, again: again)
        findings.fact("status", String(describing: library.appleStatus[imported.dictionary]))
        return findings
    }

    // MARK: - The tree

    /// Three bundles under `AssetsV2/`: Alpha (converted and read, revised, converted again), Big (cancelled), and
    /// one in a format newer than macOS installs (refused before anything is copied).
    private func writeTree() throws {
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try writeBundle(Self.alpha, name: "Alpha", version: 3, entries: [
            ("e1", "alpha", "<p>the first entry of the synthetic Alpha dictionary</p>", ["alphas"]),
            ("e2", "beta", "<p>the second entry, reached by a search key</p>", []),
        ])
        try writeBundle(Self.big, name: "Big", version: 3, entries: (0..<20_000).map { n in
            ("b\(n)", "word\(String(format: "%05d", n))", "<p>entry \(n) of the synthetic Big dictionary</p>", [])
        })
        try writeBundle(Self.refused, name: "Refused", version: 4, entries: [
            ("r1", "refused", "<p>a bundle in a format newer than the one macOS installs</p>", []),
        ])
    }

    /// Alpha as Apple might revise it: the same bundle, its entries rewritten.
    private func reviseAlpha() throws {
        try writeBundle(Self.alpha, name: "Alpha", version: 3, entries: [
            ("e1", "alpha", "<p>the first entry, as this run's revised bundle has it</p>", ["alphas"]),
            ("e2", "beta", "<p>the second entry, revised too</p>", []),
        ])
    }

    private func writeBundle(_ identifier: String, name: String, version: Int,
                             entries: [SyntheticAppleBundle.Entry]) throws {
        let root = assets.appending(path: "\(name).asset/AssetData", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var overrides = SyntheticAppleBundle.Overrides()
        overrides.plist = try SyntheticAppleBundle.plist(version: version, bundleVersion: "1.0", displayName: name,
                                                          identifier: identifier, languages: ("en", "zh-Hans"))
        try SyntheticAppleBundle.make(in: root, name: name, entries: entries, overrides)
    }

    // MARK: - The checks

    /// **Every installed bundle is listed, with what became of it.** Three rows, each a bundle of the run's own tree:
    /// two available, and the older-format one refused before the reader can choose it.
    private func listed() {
        let rows = AppleImportChoice(bundles: installed, imported: []).rows(steps: [:], locale: Locale(identifier: "en"))
        let expected: [String: AppleImportChoice.Availability] = [
            Self.alpha: .available, Self.big: .available, Self.refused: .refused(.notVersion3(found: 4)),
        ]
        var wrong: [String] = []
        for (id, availability) in expected {
            guard let row = rows.first(where: { $0.id == id }) else {
                wrong.append("\(id) is not listed")
                continue
            }
            if row.availability != availability { wrong.append("\(id) is \(row.availability)") }
        }
        let named = rows.filter { expected[$0.id] != nil }.map(\.name).sorted()
        findings.check("appleImport.listed", rows.count == expected.count && wrong.isEmpty,
                       "\(rows.count) rows \(named)"
                       + (wrong.isEmpty ? ", each with its own availability" : ": " + wrong.joined(separator: "; ")))
        findings.fact("bundles", rows.map { "\($0.id)=\($0.availability)" }.joined(separator: ","))
    }

    /// **The refusal is shown as a sentence, not hidden**: the row is refused for its version, cannot be chosen, and
    /// the sentence exists in English and in Simplified Chinese, translated rather than the English key.
    private func refusedShown() {
        let row = AppleImportChoice(bundles: installed, imported: []).rows(steps: [:]).first { $0.id == Self.refused }
        var english = AppleImportSentences.refusal(.notVersion3(found: 4)), chinese = english
        english.locale = Locale(identifier: "en")
        chinese.locale = Locale(identifier: "zh-Hans")
        let en = String(localized: english), zh = String(localized: chinese)
        let translated = !en.isEmpty && zh != en && zh.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let refused = row?.availability == .refused(.notVersion3(found: 4)) && row?.isChooseable == false
        findings.check("appleImport.refusedShown", refused && translated,
                       "row \(String(describing: row?.availability)), chooseable \(String(describing: row?.isChooseable)); "
                       + "en: \(en) | zh-Hans: \(zh)")
    }

    private struct Imported {
        let dictionary: UUID
        let record: AppleSourceRecord
    }

    /// **A chosen bundle is converted by the service and joins the library**: copied into the container, converted,
    /// imported like any other dictionary, opened and answering.
    private func converted() async -> Imported? {
        guard let alpha = installed.first(where: { $0.identifier == Self.alpha }) else {
            findings.check("appleImport.converted", false, "the run's own Alpha bundle was not discovered")
            return nil
        }
        importer.importBundles([alpha])
        let settledImport = await importer.settled(within: .seconds(300))
        let step = importer.steps[Self.alpha]
        let settledLibrary = await library.settled(within: .seconds(300))
        guard case .added(let dictionary)? = step else {
            findings.check("appleImport.converted", false,
                           "the import ended \(String(describing: step)) after "
                           + "\(settledImport ? "settling" : "the limit"); notices \(library.notices)")
            return nil
        }
        let entry = library.entries.first { $0.id == dictionary }
        let pass = settledImport && settledLibrary && entry?.appleSource != nil && library.phases[dictionary] == .ready
            && library.importedAppleBundles.contains(Self.alpha)
        findings.check("appleImport.converted", pass,
                       "step \(String(describing: step)), settled \(settledImport)/\(settledLibrary), phase "
                       + "\(String(describing: library.phases[dictionary])), conversion "
                       + "\(entry?.appleSource?.conversion.uuidString ?? "none"); notices \(library.notices)")
        guard let record = entry?.appleSource else { return nil }
        findings.fact("conversion", record.conversion.uuidString)
        findings.fact("edition", entry?.edition?.rawValue ?? "none")
        return Imported(dictionary: dictionary, record: record)
    }

    /// **The converted dictionary reads**: its words answer, including a search key the converter turned into a
    /// redirect.
    private func reads(_ dictionary: UUID) async {
        let handle = library.handle(dictionary)
        let hits = await lookup(handle, "alpha")
        let redirect = await lookup(handle, "alphas")
        findings.check("appleImport.reads", (hits ?? 0) > 0 && (redirect ?? 0) > 0,
                       "alpha: \(hits.map(String.init) ?? "no answer"); alphas (a search key): "
                       + "\(redirect.map(String.init) ?? "no answer"); handle \(String(describing: handle))")
    }

    /// **An imported bundle is not offered again**: the sheet says Already imported, and it cannot be ticked.
    private func alreadyImported() {
        let row = AppleImportChoice(bundles: installed, imported: library.importedAppleBundles)
            .rows(steps: importer.steps).first { $0.id == Self.alpha }
        findings.check("appleImport.alreadyImported", row?.availability == .alreadyImported && row?.isChooseable == false,
                       "row \(String(describing: row?.availability)), chooseable \(String(describing: row?.isChooseable))")
    }

    /// **A cancelled import leaves nothing**: no dictionary in the library, no staging folder, and no conversion
    /// folder the library could read — except one the conversion itself won the race with, which is unreferenced and
    /// is removed here as the launch sweep would remove it after a day.
    private func cancelLeavesNothing() async {
        guard let big = installed.first(where: { $0.identifier == Self.big }) else {
            findings.check("appleImport.cancelLeavesNothing", false, "the run's own Big bundle was not discovered")
            return
        }
        let conversionsBefore = conversionFolders()
        let stagingBefore = staging()
        importer.importBundles([big])
        var cancelledAt: AppleImportStep?
        poll: for _ in 0..<4_000 {
            guard let step = importer.steps[Self.big] else { break }
            switch step {
            case .copying, .converting:
                cancelledAt = step
                await importer.cancel(Self.big)
                break poll
            case .added, .failed, .cancelled:
                break poll
            case .waiting, .cancelling:
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        _ = await importer.settled(within: .seconds(300))
        _ = await library.settled(within: .seconds(300))
        let ended = importer.steps[Self.big]
        let stagingNow = staging()
        let newConversions = conversionFolders().subtracting(conversionsBefore)
        let referenced = library.appleConversions ?? []
        let orphaned = newConversions.filter { !referenced.contains($0) }
        for id in orphaned {
            try? FileManager.default.removeItem(at: container.appending(path: id.uuidString, directoryHint: .isDirectory))
        }
        let pass = ended == .cancelled && !library.importedAppleBundles.contains(Self.big)
            && stagingNow.isSubset(of: stagingBefore) && orphaned.count == newConversions.count
        findings.check("appleImport.cancelLeavesNothing", pass,
                       "cancelled \(String(describing: cancelledAt)), ended \(String(describing: ended)); "
                       + "staging \(stagingNow.count) folder(s); new conversion folders \(newConversions.count), "
                       + "\(orphaned.count) unreferenced (removed); imported "
                       + "\(library.importedAppleBundles.contains(Self.big))")
    }

    /// **Apple's change is noticed**: the bundle's files changed under the same identifier, and the library offers
    /// Convert Again rather than silently reading stale content.
    private func updateOffered(_ dictionary: UUID) async -> InstalledBundle? {
        do {
            try reviseAlpha()
        } catch {
            findings.check("appleImport.updateOffered", false, "the revised bundle could not be written: \(error)")
            return nil
        }
        installed = InstalledBundles.discover(root: assets)
        await importer.checkForUpdates(installed: installed)
        let status = library.appleStatus[dictionary]
        let revised = installed.first { $0.identifier == Self.alpha }
        findings.check("appleImport.updateOffered", status == .updated && revised != nil,
                       "status \(String(describing: status)), bundle "
                       + "\(revised.map { "v\($0.version ?? "?") \($0.bytes) B" } ?? "not found")")
        return status == .updated ? revised : nil
    }

    /// **Convert Again joins the lineage**: still one dictionary, a new edition, its join recorded so it can be undone,
    /// and the bundle current again.
    private func convertAgainJoins(_ dictionary: UUID, from bundle: InstalledBundle) async -> UUID? {
        let editionBefore = library.entries.first { $0.id == dictionary }?.edition
        importer.convertAgain(dictionary, from: bundle)
        let settledImport = await importer.settled(within: .seconds(300))
        let settledLibrary = await library.settled(within: .seconds(300))
        let step = importer.steps[Self.alpha]
        let entry = library.entries.first { $0.id == dictionary }
        let one = library.entries.filter { $0.appleSource?.bundleIdentifier == Self.alpha }.count == 1
        let changed = entry?.edition != nil && entry?.edition != editionBefore
        let joined = entry?.join != nil
        let current = library.appleStatus[dictionary] == .current
        findings.check("appleImport.convertAgainJoins",
                       step == .added(dictionary) && settledImport && settledLibrary && one && changed && joined && current,
                       "step \(String(describing: step)), one dictionary \(one), edition "
                       + "\(editionBefore?.rawValue ?? "none") → \(entry?.edition?.rawValue ?? "none"), joined \(joined), "
                       + "status \(String(describing: library.appleStatus[dictionary]))")
        guard let record = entry?.appleSource, joined else { return nil }
        findings.fact("conversionAgain", record.conversion.uuidString)
        return record.conversion
    }

    /// **A bundle removed from the Mac changes nothing about reading**: the status says removed, and the converted
    /// dictionary still answers.
    private func removedStillReads(_ dictionary: UUID, bundle: InstalledBundle) async {
        do {
            try FileManager.default.removeItem(at: bundle.url)
        } catch {
            findings.check("appleImport.removedStillReads", false,
                           "the revised bundle could not be removed from the run's own tree: \(error)")
            return
        }
        installed = InstalledBundles.discover(root: assets)
        await importer.checkForUpdates(installed: installed)
        let hits = await lookup(library.handle(dictionary), "alpha")
        findings.check("appleImport.removedStillReads",
                       library.appleStatus[dictionary] == .removed && (hits ?? 0) > 0,
                       "status \(String(describing: library.appleStatus[dictionary])), hits "
                       + "\(hits.map(String.init) ?? "no answer")")
    }

    /// **The launch sweep removes what no library names, and keeps what it does**: a staging folder and an old
    /// conversion are removed; the Convert Again conversion is kept; the first conversion, young and unreferenced, is
    /// kept for a day. The sweep touches only the run's own folders: a container holding a conversion this run did not
    /// make is refused, since the scratch library cannot vouch for it.
    private func sweptAtLaunch(first: UUID, again: UUID) {
        let ours: Set<UUID> = [first, again]
        let foreign = conversionFolders().subtracting(ours)
        guard foreign.isEmpty else {
            findings.check("appleImport.sweptAtLaunch", false,
                           "the app-group container holds \(foreign.count) conversion folder(s) this run did not make "
                           + "(\(foreign.map(\.uuidString).sorted())), so the launch sweep was not run against it")
            return
        }
        let plantedStaging = UUID().uuidString
        let plantedOutput = UUID()
        let stagingRoot = SharedContainer.staging(in: container)
        do {
            let staged = stagingRoot.appending(path: plantedStaging, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try Data("an import that never ended".utf8).write(to: staged.appending(path: "Body.data"))
            let output = container.appending(path: plantedOutput.uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data("a conversion nothing names".utf8).write(to: output.appending(path: "dictionary.mdx"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -25 * 60 * 60)],
                                                  ofItemAtPath: output.path)
        } catch {
            findings.check("appleImport.sweptAtLaunch", false, "the planted leftovers could not be written: \(error)")
            return
        }
        let report = importer.sweep()
        let keptAgain = FileManager.default.fileExists(
            atPath: container.appending(path: again.uuidString, directoryHint: .isDirectory).path)
        let plantedGone = !FileManager.default.fileExists(atPath: stagingRoot.appending(path: plantedStaging).path)
            && !FileManager.default.fileExists(atPath: container.appending(path: plantedOutput.uuidString).path)
        let pass = report?.staging.contains(plantedStaging) == true && report?.outputs == [plantedOutput]
            && report?.young.contains(first) == true && keptAgain && plantedGone
        findings.check("appleImport.sweptAtLaunch", pass,
                       "swept staging \(report?.staging ?? []), outputs \(report?.outputs.map(\.uuidString) ?? []), "
                       + "young \(report?.young.map(\.uuidString) ?? []); the Convert Again conversion kept \(keptAgain)")
    }

    // MARK: - Helpers

    private static let page = LookupOptions(limit: 10, offset: 0, mode: .reader, generation: nil)

    private func lookup(_ dict: DictId?, _ query: String) async -> Int? {
        guard let dict, case .success(let delivered) = await client.call(.lookup(query: query, dicts: [dict], options: Self.page)),
              case .page(let page) = delivered.answer else { return nil }
        return page.hits.count
    }

    private func conversionFolders() -> Set<UUID> { ContainerSnapshot.conversionFolders(in: container) }

    private func staging() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: SharedContainer.staging(in: container).path)) ?? [])
    }
}

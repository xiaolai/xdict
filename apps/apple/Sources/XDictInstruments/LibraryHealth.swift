import Foundation
import XDictClient
import XDictContract
import XDictLibrary

/// **The health check with the owner's dictionaries** (plan-macos-v1 WI-12, done-when; the E2E `library.health`
/// sub-stage), one launch of the app: the corpus folder added to a library of its own, every dictionary imported and
/// opened, then checked by the service in the background, as a reader's would be.
///
/// - `health.everyDictionaryChecked`: every dictionary's check finishes.
/// - `health.findingsMatchCore`: what each tells the reader — kind, count and the file it names — is what the core's own
///   corpus test (`core/xdict-core/tests/health_corpus.rs`) found for the same edition on a build Mac, as
///   `Tools/library/health-expected.json` keeps it (counts and file names only, no dictionary content). That test's
///   classes match the census of 2026-10-15 (`dev-docs/measurements/2026-10-15-mdx-health/`) wherever the owner's
///   decisions of that day did not change a class.
/// - `health.keptForTheEdition`: a second library over the same files is answered from the kept reports, every one
///   within a few seconds, not checked again.
@MainActor
public struct LibraryHealth {
    let client: ServiceClient
    let store: LibraryStore

    public init(client: ServiceClient, libraryDirectory: URL) {
        self.client = client
        store = LibraryStore(directory: libraryDirectory)
    }

    /// One expected finding: its kind's raw value, count, and the file it names.
    public struct Expected: Hashable, Sendable, CustomStringConvertible {
        let kind: String
        let count: UInt64
        let name: String?

        public var description: String { "\(kind) \(count)\(name.map { " \($0)" } ?? "")" }
    }

    /// `health-expected.json`: per folder, `entries` and `findings`, each `[kind, count, name or null]`.
    public nonisolated static func expected(_ data: Data) -> [String: (entries: UInt64, findings: [Expected])]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: (entries: UInt64, findings: [Expected])] = [:]
        for (folder, value) in root {
            guard let dict = value as? [String: Any], let entries = (dict["entries"] as? NSNumber)?.uint64Value,
                  let rows = dict["findings"] as? [[Any]] else { return nil }
            var findings: [Expected] = []
            for row in rows {
                guard row.count == 3, let kind = row[0] as? String, let count = (row[1] as? NSNumber)?.uint64Value else {
                    return nil
                }
                findings.append(Expected(kind: kind, count: count, name: row[2] as? String))
            }
            out[folder] = (entries, findings)
        }
        return out
    }

    /// Every way the reports differ from what was expected, by folder: a folder missing either side, its entries, or its
    /// findings in order.
    public nonisolated static func mismatches(expected: [String: (entries: UInt64, findings: [Expected])],
                                  got: [String: Health]) -> [String] {
        var out: [String] = []
        for folder in Set(expected.keys).union(got.keys).sorted() {
            guard let want = expected[folder] else { out.append("\(folder): not expected"); continue }
            guard let health = got[folder] else { out.append("\(folder): no report"); continue }
            let have = health.findings.map { Expected(kind: $0.kind.rawValue, count: $0.count, name: $0.name) }
            if health.entries != want.entries { out.append("\(folder): \(health.entries) entries, not \(want.entries)") }
            if have != want.findings { out.append("\(folder): \(have) — expected \(want.findings)") }
        }
        return out
    }

    /// Imports `corpus` into a library of its own, waits for every check, and compares. Answers the findings and every
    /// finding the reader was told, for the app to check their sentences.
    public func run(_ corpus: URL, expected: [String: (entries: UInt64, findings: [Expected])]) async
        -> (Findings, [HealthFinding]) {
        var findings = Findings()
        let library = Library(store: store, backend: client)
        await library.start()
        library.add([corpus])
        await library.settle("health.import", within: .seconds(1500), &findings)
        let began = ContinuousClock.now
        let reports = await Self.checked(library, within: .seconds(1500))
        findings.fact("healthSeconds", milliseconds(ContinuousClock.now - began))
        let unchecked = library.entries.filter { reports[$0.id] == nil }
            .map { "\(LibraryCorpus.folder($0)): \(String(describing: library.health[$0.id]))" }
        findings.check("health.everyDictionaryChecked", unchecked.isEmpty && !library.entries.isEmpty,
                       "\(reports.count) of \(library.entries.count) checked; not: \(unchecked.prefix(5))")
        var byFolder: [String: Health] = [:]
        for entry in library.entries { if let report = reports[entry.id] { byFolder[LibraryCorpus.folder(entry)] = report } }
        let differ = Self.mismatches(expected: expected, got: byFolder)
        findings.check("health.findingsMatchCore", differ.isEmpty && !expected.isEmpty,
                       differ.isEmpty ? "\(byFolder.count) dictionaries, \(byFolder.values.map(\.findings.count).reduce(0, +)) findings"
                                      : "\(differ.count) differ: \(differ.prefix(4))")
        // Again, over the same files: the reports are the edition's, kept beside its index.
        let again = Library(store: store, backend: client)
        await again.start()
        await again.settle("health.reopen", within: .seconds(600), &findings)
        let reopened = ContinuousClock.now
        let kept = await Self.checked(again, within: .seconds(60))
        let keptFor = ContinuousClock.now - reopened
        findings.fact("keptSeconds", milliseconds(keptFor))
        let same = again.entries.allSatisfy { kept[$0.id] != nil && kept[$0.id] == reports[$0.id] }
        findings.check("health.keptForTheEdition", same && !again.entries.isEmpty && keptFor < .seconds(30),
                       "\(kept.count) of \(again.entries.count) answered in \(milliseconds(keptFor)) ms, the same: \(same)")
        let told = reports.values.flatMap(\.findings)
        return (findings, told)
    }

    /// Each dictionary's report once every check has ended (checked or not), or at the limit.
    static func checked(_ library: Library, within limit: Duration) async -> [UUID: Health] {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            let pending = library.entries.contains { entry in
                switch library.health[entry.id] {
                case .checked, .unavailable: false
                case .checking, nil: library.phases[entry.id] == .ready
                }
            }
            if !pending { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        var out: [UUID: Health] = [:]
        for entry in library.entries { if case .checked(let report) = library.health[entry.id] { out[entry.id] = report } }
        return out
    }
}

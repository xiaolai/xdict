import Foundation
import XDictClient
import XDictContract
import XDictLibrary

/// **The library with the owner's dictionaries** (plan-macos-v1 WI-5, done-when; the E2E `library` stage), in three
/// launches of the app, so that what survives is what the library's file and the bookmarks in it carry:
///
/// 1. `importing`: the corpus folder added as a reader adds it, every dictionary registered with the edition
///    `index_bench` computed on the build Mac; then the reader's choices made (the order reversed, one renamed, one
///    switched off) and written down beside the library as `snapshot.json`.
/// 2. `relaunch`, after the stage moved the corpus folder: every dictionary of the snapshot there, in its order, with
///    its edition, name and switch, found under the folder's new place, and answering a lookup. With relinking off (the
///    positive control) they are missing.
/// 3. `rewrite`: the smallest dictionary's file rewritten (`ChangedEdition`): a new edition, joined to its lineage only
///    when the reader says so, and the join undone.
@MainActor
public struct LibraryCorpus {
    public struct Row: Codable, Equatable, Sendable {
        let id: UUID
        let folder: String
        let edition: String?
        let enabled: Bool
        let readersName: String?
    }

    let client: ServiceClient
    let store: LibraryStore

    public init(client: ServiceClient, libraryDirectory: URL) {
        self.client = client
        store = LibraryStore(directory: libraryDirectory)
    }

    var snapshotFile: URL { store.directory.appending(path: "snapshot.json") }

    static func folder(_ entry: LibraryEntry) -> String {
        URL(fileURLWithPath: entry.mdx?.location.path ?? "").deletingLastPathComponent().lastPathComponent
    }

    static func rows(_ library: Library) -> [Row] {
        library.entries.map { Row(id: $0.id, folder: folder($0), edition: $0.edition?.rawValue, enabled: $0.enabled,
                                  readersName: $0.readersName) }
    }

    /// `expected` is the folder name of each dictionary and its edition, from `index_bench import-all`'s registry.
    public func importing(_ corpus: URL, expected: [String: String]) async -> Findings {
        var findings = Findings()
        let library = Library(store: store, backend: client)
        await library.start()
        let began = ContinuousClock.now
        let added = library.add([corpus])
        await library.settle("corpus.import", within: .seconds(1500), &findings)
        findings.fact("importSeconds", milliseconds(ContinuousClock.now - began))
        let notReady = library.entries.filter { library.phases[$0.id] != .ready }
            .map { "\(Self.folder($0)): \(String(describing: library.phases[$0.id]))" }
        findings.check("corpus.registered", added.count == expected.count && library.entries.count == expected.count
                       && notReady.isEmpty && !expected.isEmpty,
                       "\(added.count) added, \(expected.count) expected; not ready: \(notReady); notices \(library.notices)")
        let mismatched = library.entries.compactMap { entry -> String? in
            let folder = Self.folder(entry)
            return expected[folder] == entry.edition?.rawValue ? nil
                : "\(folder): \(entry.edition?.rawValue ?? "none") vs index_bench \(expected[folder] ?? "none")"
        }
        let absent = Set(expected.keys).subtracting(library.entries.map(Self.folder)).sorted()
        findings.check("corpus.editions", mismatched.isEmpty && absent.isEmpty && !expected.isEmpty,
                       "\(library.entries.count - mismatched.count) of \(expected.count) editions are index_bench's; "
                       + "differing \(mismatched), absent \(absent)")

        // The reader's choices: the order reversed, the first renamed, the last switched off.
        let ids = library.entries.map(\.id)
        for (target, id) in ids.reversed().enumerated() {
            guard let at = library.entries.firstIndex(where: { $0.id == id }) else { continue }
            library.move(fromOffsets: IndexSet(integer: at), toOffset: target)
        }
        if let first = library.entries.first { library.rename(first.id, "Renamed by the E2E run") }
        if let last = library.entries.last { library.setEnabled(last.id, false) }
        let rows = Self.rows(library)
        findings.check("corpus.choicesMade", rows.map(\.id) == Array(ids.reversed()) && rows.count == ids.count,
                       "order \(rows.map(\.folder))")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: snapshotFile, options: .atomic)
        } catch {
            findings.check("corpus.snapshot", false, "the snapshot could not be written: \(error)")
        }
        return findings
    }

    public func relaunch(movedTo: URL, relinking: Bool) async -> Findings {
        var findings = Findings()
        guard let data = try? Data(contentsOf: snapshotFile), let before = try? JSONDecoder().decode([Row].self, from: data)
        else {
            findings.check("relaunch.everyDictionary", false, "no snapshot at \(snapshotFile.path): run the import first")
            return findings
        }
        let library = Library(store: store, backend: client, options: Library.Options(relinking: relinking))
        await library.start()
        await library.settle("corpus.relaunch", within: .seconds(600), &findings)
        let after = Self.rows(library)
        let lost = library.entries.filter { library.phases[$0.id] != .ready }
            .map { "\($0.mdx?.fileName ?? "?"): \(String(describing: library.phases[$0.id]))" }
        findings.fact("relinking", "\(relinking)")
        findings.check("relaunch.everyDictionary", Set(after.map(\.id)) == Set(before.map(\.id)) && lost.isEmpty
                       && !before.isEmpty, "\(after.count - lost.count) of \(before.count) answering; not: \(lost.prefix(5))")
        findings.check("relaunch.order", after.map(\.id) == before.map(\.id)
                       && after.map(\.readersName) == before.map(\.readersName) && after.map(\.enabled) == before.map(\.enabled)
                       && after.map(\.edition) == before.map(\.edition), "order \(after.map(\.folder).prefix(5))…")
        // The library keeps canonical paths; the place the stage names may go through a link (`/tmp`).
        let moved = FileLocator.canonical(movedTo) ?? movedTo
        let elsewhere = library.entries.filter { !($0.mdx?.location.path.hasPrefix(moved.path + "/") ?? false) }
        findings.check("relaunch.foundWhereMoved", elsewhere.isEmpty && !library.entries.isEmpty,
                       "\(library.entries.count - elsewhere.count) found under \(movedTo.lastPathComponent)")
        var silent: [String] = []
        for entry in library.entries {
            guard let dict = library.handle(entry.id), case .success(let delivered) = await client.call(.lookup(
                query: "a", dicts: [dict], options: LookupOptions(limit: 1, offset: 0, mode: .reader, generation: nil))),
                  case .page = delivered.answer else {
                silent.append(Self.folder(entry))
                continue
            }
        }
        findings.check("relaunch.answering", silent.isEmpty && !library.entries.isEmpty,
                       "\(library.entries.count - silent.count) answered a lookup; silent \(silent.prefix(5))")
        return findings
    }

    public func rewrite() async -> Findings {
        var findings = Findings()
        let library = Library(store: store, backend: client)
        await library.start()
        await library.settle("corpus.rewrite", within: .seconds(600), &findings)
        func size(_ entry: LibraryEntry) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: entry.mdx?.location.path ?? "")[.size] as? Int) ?? .max
        }
        guard let smallest = library.entries.filter({ library.phases[$0.id] == .ready }).min(by: { size($0) < size($1) })
        else {
            findings.check("corpus.changed.newEdition", false, "no dictionary is ready")
            return findings
        }
        findings.fact("rewritten", Self.folder(smallest))
        await ChangedEdition(client: client, store: store, prefix: "corpus.changed", limit: .seconds(600)).check(library, id: smallest.id, rewrite: { beside in
            // The same bytes and one more: a new edition the reader still reads (the MDX's sections ignore a trailing
            // byte, measured 2026-10-14 with index_bench on PEU).
            let original = URL(fileURLWithPath: smallest.mdx?.location.path ?? "")
            try FileManager.default.copyItem(at: original, to: beside)
            let handle = try FileHandle(forWritingTo: beside)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x0A]))
            try handle.close()
        }, &findings)
        return findings
    }
}

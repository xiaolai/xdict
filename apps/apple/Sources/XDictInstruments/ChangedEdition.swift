import Foundation
import XDictClient
import XDictContract
import XDictLibrary

/// **A file rewritten under the library** (L5; ADR-0002 decision 3, as amended 2026-10-14), checked the same way for a
/// generated dictionary and for one of the owner's: rewritten as an updater would (the new file written beside it and
/// renamed over it), noticed as a changed edition at the next open, imported again as a new edition with a lineage of
/// its own and a question to the reader; joined to the dictionary's lineage only when the reader says so, kept so in
/// the library's file, and undone back to the lineage its import gave it — each asked of the service, not read off the
/// library.
@MainActor
struct ChangedEdition {
    let client: ServiceClient
    let store: LibraryStore
    /// Prefixes every check's name: `changed` in the scenario, `corpus.changed` with the owner's dictionaries.
    let prefix: String
    /// How long the rewritten file's import, and every other dictionary's reopening, may take.
    let limit: Duration

    func check(_ library: Library, id: UUID, rewrite: (URL) throws -> Void, _ findings: inout Findings) async {
        func named(_ check: String) -> String { "\(prefix).\(check)" }
        guard let first = library.entries.first(where: { $0.id == id }), let e1 = first.edition, let l1 = first.lineage,
              let path = first.mdx?.location.path else {
            return findings.check(named("newEdition"), false, "the dictionary was not imported: \(String(describing: library.phases[id]))")
        }
        let file = URL(fileURLWithPath: path), beside = file.deletingLastPathComponent().appending(path: ".xdict-rewrite.tmp")
        do {
            try rewrite(beside)
            guard rename(beside.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            return findings.check(named("newEdition"), false, "the file could not be rewritten: \(error)")
        }
        await library.refresh()
        await library.settle(named("refresh"), within: limit, &findings)
        let now = library.entries.first { $0.id == id }
        guard let offer = now?.offer, let e2 = now?.edition else {
            return findings.check(named("newEdition"), false, "no question was asked: edition "
                                  + "\(now?.edition?.rawValue ?? "none"), phase \(String(describing: library.phases[id]))")
        }
        findings.check(named("newEdition"), e2 != e1 && offer.edition == e2 && offer.earlierEdition == e1
                       && offer.earlierLineage == l1 && library.phases[id] == .ready,
                       "\(e1.rawValue.suffix(8)) → \(e2.rawValue.suffix(8)), phase \(String(describing: library.phases[id]))")
        let unasked = await lineage(of: e2)
        findings.check(named("notJoinedUnasked"), unasked == offer.mintedLineage && unasked != l1,
                       "before the reader answers, the new edition's lineage is \(unasked?.rawValue ?? "none") "
                       + "(its own \(offer.mintedLineage.rawValue), the dictionary's \(l1.rawValue))")
        let accepted = await library.acceptJoin(id)
        let joined = await lineage(of: e2)
        findings.check(named("joined"), accepted && joined == l1 && library.entries.first { $0.id == id }?.lineage == l1,
                       "joined \(accepted): the service says \(joined?.rawValue ?? "none")")
        let kept = (try? store.load())?.entries.first { $0.id == id }
        findings.check(named("persists"), kept?.join?.previous == offer.mintedLineage && kept?.lineage == l1,
                       "stored join \(kept?.join.map { "\($0.joinedTo.rawValue) undone by \($0.previous.rawValue)" } ?? "none")")
        let undone = await library.undoJoin(id)
        let split = await lineage(of: e2)
        findings.check(named("undone"), undone && split == offer.mintedLineage
                       && library.entries.first { $0.id == id }?.join == nil,
                       "undone \(undone): the service says \(split?.rawValue ?? "none")")
    }

    func lineage(of edition: Edition) async -> LineageId? {
        guard case .success(let delivered) = await client.call(.lineageOf(edition: edition)),
              case .lineage(let lineage) = delivered.answer else { return nil }
        return lineage
    }
}

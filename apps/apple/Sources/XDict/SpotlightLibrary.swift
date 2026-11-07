import Foundation
import XDictClient
import XDictContract
import XDictLibrary
import XDictSpotlight

/// **Indexing the reader's library on the reader's word** (plan-setup-v2 WI-6; ADR-0028): one run at a time, one
/// dictionary at a time, its words paged from the dictionary service — which reads only the edition's index — and its
/// domain deleted when the reader turns the switch off. Nothing of an entry is read or stored: the words are the whole
/// of what travels.
@MainActor
final class SpotlightLibrary {
    /// How many words a page asks the service for.
    static let page: UInt32 = 1_000

    private let library: Library
    private let client: ServiceClient
    private let indexer: SpotlightIndexer
    private let ledger: SpotlightLedger

    init(library: Library, client: ServiceClient,
         indexer: SpotlightIndexer = SpotlightIndexer(index: SystemSpotlightIndex()),
         ledger: SpotlightLedger = SpotlightLedger()) {
        self.library = library
        self.client = client
        self.indexer = indexer
        self.ledger = ledger
    }

    /// What one run came to, in words the reader can be told.
    enum Outcome: Equatable, Sendable {
        case indexed(dictionaries: Int, words: Int)
        case deleted(dictionaries: Int)
        /// The index or the service refused; nothing is claimed to have happened.
        case failed(String)

        /// Whether nothing was achieved: the index or the service refused, or the run was stopped.
        public var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    /// **The switch, obeyed** (owner, 2026-10-27): on means every dictionary the index does not already hold, at the
    /// edition it holds, is written — nothing else is touched, so a launch over an unchanged library costs no Spotlight
    /// work at all; off means every XDict domain comes out. A run is not cancellable by a second switch — the settings
    /// value is the order, and the next run is what follows it — so a failure is reported rather than left as a silent
    /// half-index. **The off-run places its deletion and returns** (2026-10-27): Core Spotlight receives that call and
    /// does not answer it on macOS 27, so waiting would owe it again at every launch — `SystemSpotlightIndex.deleteAll`.
    func apply(_ on: Bool, onLateFailure: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        guard on else {
            do {
                // **Everything this app indexed, in one call**, and the record of it goes with it.
                try await indexer.deleteAll(onLateFailure: onLateFailure)
                ledger.clear()
                return .deleted(dictionaries: 0)
            } catch {
                return .failed(String(describing: error))
            }
        }
        // **What the library has now**: only an enabled dictionary with an edition and an open handle can be indexed.
        var libraryNow: [SpotlightPlan.Update] = []
        var skipped = 0
        var handles: [String: DictId] = [:]
        for entry in library.entries where entry.enabled {
            guard let edition = entry.edition?.rawValue else { continue }
            guard let dict = library.handle(entry.id) else {
                skipped += 1
                continue
            }
            let domain = entry.id.uuidString
            libraryNow.append(SpotlightPlan.Update(domain: domain, edition: edition))
            handles[domain] = dict
        }
        let plan = SpotlightPlan.make(library: libraryNow, indexed: ledger.indexed)
        var words = 0
        var indexed = 0
        do {
            if !plan.removing.isEmpty {
                try await indexer.delete(domains: plan.removing)
                ledger.forget(domains: plan.removing)
            }
            for update in plan.updating {
                guard let dict = handles[update.domain] else { continue }
                // **A changed edition replaces its own domain**: the old edition's words never outlive it.
                try await indexer.delete(domains: [update.domain])
                let client = self.client
                let planned = update.edition
                let run = try await indexer.index(domain: update.domain) { @Sendable from in
                    try await Self.nextPage(client: client, dict: dict, from: from, planned: planned)
                }
                ledger.record(domain: update.domain, edition: update.edition)
                words += run.stored
                indexed += 1
            }
        } catch is CancellationError {
            return .failed("cancelled")
        } catch {
            return .failed(String(describing: error))
        }
        guard skipped == 0 else { return .failed("\(skipped) dictionaries were not ready") }
        return .indexed(dictionaries: indexed, words: words)
    }

    /// **One page, or nil at the end — and a refusal is a refusal.** A service that does not answer throws, so a run
    /// cannot report "indexed" over a half-read library (audit-fix 2026-10-22).
    private static func nextPage(client: ServiceClient, dict: DictId, from: UInt64,
                                 planned: String) async throws -> SpotlightIndexer.Page? {
        let outcome = await client.call(.words(dict: dict, from: from, limit: page))
        guard case .success(let delivered) = outcome, case .words(let words) = delivered.answer else {
            throw SpotlightFailure.service
        }
        return try checkedPage(edition: words.edition.rawValue, words: words.words, next: words.next, planned: planned)
            .map { SpotlightIndexer.Page(words: $0.words, next: $0.next) }
    }

    /// **Every page must be of the edition the plan names, the first included**: the ledger records the run under that
    /// edition, so a page from another — the dictionary reopened or replaced under the run — is refused and indexed again
    /// by the next run. The first page used to set the edition, so a replacement before it was indexed and recorded
    /// under the old edition's name.
    nonisolated static func checkedPage(edition: String, words: [String], next: UInt64,
                                        planned: String) throws -> (words: [String], next: UInt64)? {
        guard edition == planned else { throw SpotlightFailure.editionChanged }
        guard !words.isEmpty else { return nil }
        return (words, next)
    }

    /// Refusals a run can meet, as kinds.
    enum SpotlightFailure: Error, Equatable {
        case service
        case editionChanged
    }
}

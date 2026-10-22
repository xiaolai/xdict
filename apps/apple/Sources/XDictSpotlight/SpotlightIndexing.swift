import CoreSpotlight
import Foundation

/// **The index, behind a seam** (plan-setup-v2 WI-6): every test drives a fake, so what is checked is the batching, the
/// domains, the cancellation and the failures, never Core Spotlight's own behaviour. The real one is
/// `CSSearchableIndex.default()`, the index of this Mac.
public protocol SpotlightIndexing: Sendable {
    /// Stores these items, replacing any with the same identifiers. **It speaks `SpotlightItem`, not CoreSpotlight's
    /// own type**: that one is not `Sendable`, so a seam that took it could not be an actor, and every test's fake is one.
    func index(_ items: [SpotlightItem]) async throws
    /// Deletes everything in these domains.
    func delete(domains: [String]) async throws
    /// **Deletes everything this app ever indexed**: Core Spotlight's index is XDict's own, so turning the switch off
    /// takes every domain with one call — including the ones a dictionary that has since been removed left behind
    /// (audit-fix 2026-10-22).
    func deleteAll() async throws
}

/// The system's index: `CSSearchableIndex.default()`, whose completions arrive on a queue of its own.
public struct SystemSpotlightIndex: SpotlightIndexing {
    public init() {}

    public func index(_ items: [SpotlightItem]) async throws {
        let index = CSSearchableIndex.default()
        let searchable = items.map(SpotlightItems.item)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.indexSearchableItems(searchable) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    public func delete(domains: [String]) async throws {
        let index = CSSearchableIndex.default()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domains) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    public func deleteAll() async throws {
        let index = CSSearchableIndex.default()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.deleteAllSearchableItems { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

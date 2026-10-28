import CoreSpotlight
import Foundation
import os

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
    /// **The same deletion, with a report of a refusal that arrives afterwards** (audit, 2026-10-28): the order is
    /// placed and the run recorded before any answer, so a late error is the one fact that says the deletion is still
    /// owed. A seam that cannot report one inherits the default below and loses nothing.
    func deleteAllReportingLateFailure(_ onLateFailure: @escaping @Sendable (String) -> Void) async throws
}

extension SpotlightIndexing {
    /// Deletes everything, reporting nothing: what a seam with no late answers does.
    public func deleteAllReportingLateFailure(_ onLateFailure: @escaping @Sendable (String) -> Void) async throws {
        try await deleteAll()
    }
}

/// The system's index: `CSSearchableIndex.default()`, whose completions arrive on a queue of its own — and, as
/// `SpotlightDeadline` says, sometimes not at all, so every call here is bounded.
public struct SystemSpotlightIndex: SpotlightIndexing {
    public init() {}

    public func index(_ items: [SpotlightItem]) async throws {
        let index = CSSearchableIndex.default()
        let searchable = items.map(SpotlightItems.item)
        try await SpotlightDeadline.bounded { done in
            index.indexSearchableItems(searchable) { error in done(error) }
        }
    }

    public func delete(domains: [String]) async throws {
        let index = CSSearchableIndex.default()
        try await SpotlightDeadline.bounded { done in
            index.deleteSearchableItems(withDomainIdentifiers: domains) { error in done(error) }
        }
    }

    /// **The order, not a receipt** (measured 2026-10-27): `corespotlightd` receives this call — its log names the
    /// bundle and the request — and on this Mac never answers it. All three Core Spotlight calls were probed with the
    /// run loop free, from a standalone program and from the app: every order arrived, no completion came back in
    /// 30 s or in 300. Waiting for that reply left the switch owing the same deletion at every launch, so the order
    /// is sent and the run is recorded as placed. A completion that does arrive, late, is logged where it can be seen.
    /// **A late refusal is reported, not just logged** (audit, 2026-10-28): the run is recorded as placed before an
    /// answer can arrive, so an error that comes back afterwards is the one fact that says the deletion is still owed.
    /// `onLateFailure` puts it back in the app's debt; the log keeps it visible either way.
    public func deleteAll() async throws {
        try await deleteAllReportingLateFailure { _ in }
    }

    public func deleteAllReportingLateFailure(_ onLateFailure: @escaping @Sendable (String) -> Void) async throws {
        Self.place(CSSearchableIndex.default(), onLateFailure: onLateFailure)
    }

    /// The order itself, made from a synchronous body: Swift points an async caller at the async alternative, which is
    /// the wait this call exists to avoid.
    private static func place(_ index: CSSearchableIndex, onLateFailure: @escaping @Sendable (String) -> Void) {
        index.deleteAllSearchableItems { error in
            if let error {
                let why = String(describing: error)
                SpotlightLog.answers.notice("deleteAll answered late: \(why, privacy: .public)")
                onLateFailure(why)
            } else {
                SpotlightLog.answers.notice("deleteAll answered late, after its run was recorded")
            }
        }
    }
}

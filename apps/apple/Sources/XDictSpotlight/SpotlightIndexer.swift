import CoreSpotlight
import Foundation

/// **Putting a library's words into the index, and taking them out again** (plan-setup-v2 WI-6; ADR-0028 decision 3):
/// batches of a fixed size, a check for cancellation between them, one failure that stops the run and is reported, and
/// deletion by domain. It knows nothing of dictionaries beyond their ids and their words.
public struct SpotlightIndexer: Sendable {
    /// How many items go to the index in one call (ADR-0028 decision 3: 200).
    public static let batch = 200

    private let index: any SpotlightIndexing

    public init(index: any SpotlightIndexing) {
        self.index = index
    }

    /// What a run did, so a caller can say it rather than guess.
    public struct Run: Equatable, Sendable {
        public let stored: Int
    }

    /// **One page as the core counts it**: the words, and the key position the next page starts at. The consumer must
    /// not compute the cursor itself — the core passes over internal keys and repeats (audit-fix 2026-10-22).
    public struct Page: Equatable, Sendable {
        public let words: [String]
        public let next: UInt64

        public init(words: [String], next: UInt64) {
            self.words = words
            self.next = next
        }
    }

    /// **A word a reader can search for**: one with a letter or a digit in it. A punctuation-only key (the corpus's `ahd`
    /// has `,`) is a public key that a reader-mode lookup folds away, so an item for it would open nothing.
    public static func isTypeable(_ word: String) -> Bool {
        word.contains { $0.isLetter || $0.isNumber }
    }

    /// **Stores one dictionary's words.** `next` hands back the next page of words, and `nil` when the dictionary is
    /// done; cancellation is checked between batches, so a library change stops the run at its next page rather than
    /// leaving a half-written domain nobody retracts.
    public func index(domain: String, next: @Sendable (UInt64) async throws -> Page?) async throws -> Run {
        var stored = 0
        var from: UInt64 = 0
        while let page = try await next(from) {
            var items: [SpotlightItem] = []
            items.reserveCapacity(min(page.words.count, Self.batch))
            for word in page.words where Self.isTypeable(word) {
                items.append(SpotlightItem(word: word, domain: domain))
                if items.count == Self.batch {
                    try Task.checkCancellation()
                    try await index.index(items)
                    stored += items.count
                    items.removeAll(keepingCapacity: true)
                }
            }
            if !items.isEmpty {
                try Task.checkCancellation()
                try await index.index(items)
                stored += items.count
            }
            if page.words.isEmpty { break }
            from = page.next
        }
        return Run(stored: stored)
    }

    /// Deletes one run's domains.
    public func delete(domains: [String]) async throws {
        guard !domains.isEmpty else { return }
        try await index.delete(domains: domains)
    }

    /// **Deletes everything this app ever indexed**: what turning the switch off promises.
    public func deleteAll() async throws {
        try await index.deleteAll()
    }
}

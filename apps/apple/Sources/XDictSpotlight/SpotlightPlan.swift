import Foundation
import Observation

/// **What the index needs, given what is already in it** (owner, 2026-10-27: a reader's 24 dictionaries made the app
/// delete and rewrite every word on every launch, millions of items of Spotlight work for a library that had not
/// changed). A dictionary is indexed once per edition: the same edition again is nothing to do, a new edition replaces
/// its own domain, and a dictionary the reader removed or disabled takes its domain out.
public struct SpotlightPlan: Equatable, Sendable {
    /// One dictionary the index can hold: its domain — the library's own id — and the edition it holds now.
    public struct Update: Equatable, Sendable {
        public let domain: String
        public let edition: String

        public init(domain: String, edition: String) {
            self.domain = domain
            self.edition = edition
        }
    }

    /// Domains to take out: dictionaries no longer enabled, no longer in the library, or about to be written afresh.
    public let removing: [String]
    /// Dictionaries to write: new, or a new edition of one already there.
    public let updating: [Update]

    public init(removing: [String], updating: [Update]) {
        self.removing = removing
        self.updating = updating
    }

    /// Whether the run has nothing to do at all — the common launch, once every dictionary is indexed.
    public var isEmpty: Bool { removing.isEmpty && updating.isEmpty }

    /// **The plan for a library against what the index holds**: `indexed` is each domain's edition as the last
    /// successful run recorded it. A domain being replaced is removed first by the caller, so an edition's stale words
    /// never outlive the edition.
    public static func make(library: [Update], indexed: [String: String]) -> SpotlightPlan {
        let wanted = Dictionary(uniqueKeysWithValues: library.map { ($0.domain, $0.edition) })
        let removing = indexed.keys.filter { wanted[$0] == nil }.sorted()
        let updating = library.filter { indexed[$0.domain] != $0.edition }
            .sorted { $0.domain < $1.domain }
        return SpotlightPlan(removing: removing, updating: updating)
    }
}

/// **What the index was last given, per dictionary** (owner, 2026-10-27): the reader's own preferences hold each
/// domain's edition, so a launch can tell "already there" from "new or changed" without reading the index.
@MainActor
public struct SpotlightLedger {
    public static let key = "spotlight.indexed"
    /// **The system the record was made on**: an OS upgrade or a reinstalled system can carry a reader's preferences and
    /// not its Spotlight index, and a record that outlived the index would promise words nothing holds. Another system
    /// reads as no record, so the library is written once more (owner, 2026-10-27).
    public static let buildKey = "spotlight.indexedBuild"

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Domain → the edition the index was last given. A value that is not this shape, or one made on another system,
    /// is no record.
    public var indexed: [String: String] {
        guard defaults.string(forKey: Self.buildKey) == Self.system else { return [:] }
        return (defaults.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
    }

    public func record(domain: String, edition: String) {
        var now = indexed
        now[domain] = edition
        defaults.set(now, forKey: Self.key)
        defaults.set(Self.system, forKey: Self.buildKey)
    }

    /// The running system, as the record names it.
    static var system: String { ProcessInfo.processInfo.operatingSystemVersionString }

    public func forget(domains: [String]) {
        guard !domains.isEmpty else { return }
        var now = indexed
        for domain in domains { now[domain] = nil }
        defaults.set(now, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

import Foundation
import Observation

/// **The reader's switch for Spotlight** (plan-setup-v2 WI-6; ADR-0028 decision 1): off until the reader turns it on,
/// kept in the app's own preferences, and the only state the setup row and the indexer share. Turning it off is a
/// promise: every XDict domain is deleted, so nothing of the reader's library is left in the system index.
@MainActor
@Observable
public final class SpotlightSettings {
    /// The preference's key, under the app's domain.
    public static let key = "spotlight.included"
    /// A deletion a failed run still owes, kept so the next launch tries again.
    public static let cleanupKey = "spotlight.cleanupPending"

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.key)   // absent is off: opt-in, never opt-out
        cleanupPending = defaults.bool(forKey: Self.cleanupKey)
    }

    /// Whether the reader has included the library in Spotlight.
    public private(set) var enabled: Bool

    /// **What the last run came to, as the row can say it** (audit-fix 2026-10-22): nil until a run has happened, true
    /// when the index or the service refused — so a switch that says "included" over an index that never took the words
    /// is a thing the reader can see.
    public private(set) var lastRunFailed: Bool?

    /// Records one run's outcome; **a failed run is remembered as still to be cleaned up**, so turning the switch off
    /// that could not delete comes back to it at the next launch rather than leaving words indexed for ever
    /// (audit-fix 2026-10-22).
    public func record(failed: Bool) {
        lastRunFailed = failed
        if !enabled { cleanupPending = failed }
        defaults.set(cleanupPending, forKey: Self.cleanupKey)
    }

    /// **A deletion still owed**: set when a run failed with the switch off, cleared when one succeeds.
    public private(set) var cleanupPending: Bool

    /// Whether the next launch must try the deletion again.
    public func needsCleanup() -> Bool { !enabled && cleanupPending }

    /// What the reader asked for, in what order it must reach the index: turning it on means indexing, turning it off
    /// means deleting, and the caller does that work (the settings value never touches the index itself).
    public enum Change: Equatable, Sendable {
        case include
        case exclude
        case none
    }

    /// Takes the switch's value and answers what the index must do about it.
    @discardableResult
    public func setEnabled(_ on: Bool) -> Change {
        guard on != enabled else { return .none }
        enabled = on
        if !on { cleanupPending = true }
        defaults.set(on, forKey: Self.key)
        defaults.set(cleanupPending, forKey: Self.cleanupKey)
        return on ? .include : .exclude
    }
}

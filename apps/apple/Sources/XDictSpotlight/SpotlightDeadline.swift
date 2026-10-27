import Foundation
import os

/// **Where an answer that arrived late, or a request that could not be placed, is written**: the app's own log, read
/// with `log show --predicate 'process == "XDict" AND category == "spotlight"'`.
public enum SpotlightLog {
    public static let answers = Logger(subsystem: "ai.xdict.app", category: "spotlight")
}

/// **A completion that never arrives is a failure, not a wait** (2026-10-27). The off-run's deletion was performed —
/// `corespotlightd`'s log shows `deleteAllSearchableItemsWithBundleID` for this app, and suggestd clearing its harvest
/// queues after it — but nothing ever told the app, so `spotlight.cleanupPending` stayed true and **every launch sent
/// the whole deletion again**, each one re-running the Spotlight delete path. Core Spotlight answers on a queue of the
/// system's own and nothing promises an answer at all, so each call is bounded here and a missed answer is thrown,
/// where before it was an await that never returned.
public struct SpotlightNoAnswer: Error, Equatable, Sendable, CustomStringConvertible {
    /// The deadline that passed, in seconds.
    public let seconds: Double

    public init(seconds: Double) { self.seconds = seconds }

    public var description: String { "the index did not answer within \(Int(seconds)) s" }
}

/// **One Core Spotlight call, and its answer or its absence.**
public enum SpotlightDeadline {
    /// How long one call may take before its answer is called missing. **Generous on purpose**: deleting a reader's
    /// index can take minutes on a busy Mac, and a deadline that fired on a slow success would owe the deletion again
    /// and repeat exactly the loop this exists to stop — so the deadline is set to catch a call that never answers,
    /// not one that answers slowly.
    public static let generous: Duration = .seconds(300)

    /// Runs a completion-style call and answers when it does, or throws `SpotlightNoAnswer` when the deadline passes
    /// first. **The first answer wins**: a completion that arrives after the deadline is dropped rather than resuming
    /// a continuation twice, which would trap.
    public static func bounded(_ deadline: Duration = generous,
                               _ start: (_ done: @escaping @Sendable (any Error?) -> Void) -> Void) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            start { error in
                guard once.claim() else { return }
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            let seconds = Double(deadline.components.seconds)
                + Double(deadline.components.attoseconds) / 1e18
            Task {
                try? await Task.sleep(for: deadline)
                guard once.claim() else { return }
                continuation.resume(throwing: SpotlightNoAnswer(seconds: seconds))
            }
        }
    }

    /// One claim, ever: the completion and the deadline race for it, and the lock makes exactly one of them win.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

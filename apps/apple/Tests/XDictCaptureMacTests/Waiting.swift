import Foundation
import Synchronization
import Testing
@testable import XDictCaptureMac

// **How a capture test waits, and the only file in this target that may block a thread** (2026-10-20). The suite stood
// still for 110 s under load on the build Mac: blocked reads in the lane tests, run on Swift's cooperative pool, and a few
// long tests had taken every thread of it, so the tests that would release those reads could not run (`LaneThreadTests`).
// The rules, held by `.swiftlint.yml`'s `capture_tests_block_only_through_waiting`:
//
// - a test waits for an **event** — work started, a value given, a gate opened — through `Wait`, which polls without
//   holding a thread; patience is how long a failure may take to show, never a speed anything must reach;
// - a fake that stands in for a request **blocked in the framework** blocks through `Blocking.until`, which only a lane's
//   own thread may do: it waits for another task to release it, and a thread of the pool so held may be the one that
//   task needed;
// - a fake request that merely **takes time** sleeps through `Blocking.for`, bounded, on any thread;
// - a test whose claim is **order** uses `AccessibilityLane.patient`, whose bounds no run reaches; a test of a bound
//   names its bounds (`AccessibilityLane(bounds:)`). Under load a short bound fires before a slow scheduler has queued
//   what the test meant to queue, and the order the test checks never happens.

/// Waiting in tests: for started work, never for a fixed time that asserts a speed.
enum Wait {
    /// Long enough to stop a failure hanging; nothing asserts that anything took this long.
    static let patience: Duration = .seconds(10)

    /// Polls `condition` a millisecond a turn until it holds or patience runs out.
    static func until(_ condition: @Sendable () -> Bool) async -> Bool {
        let end = ContinuousClock.now + patience
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    /// The task's value, or nil if patience runs out first — so a regression fails rather than hangs.
    static func value<T: Sendable>(of task: Task<T, Never>) async -> T? {
        let box = Mutex<T?>(nil)
        let watcher = Task { let value = await task.value; box.withLock { $0 = value } }
        _ = await until { box.withLock { $0 } != nil }
        watcher.cancel()
        return box.withLock { $0 }
    }

    /// Lets already-started work run, for an assertion that something did **not** happen. It cannot prove an absence,
    /// only give the absence a fair chance to be broken: a slow machine can make it miss a defect, never invent one.
    static func drain() async {
        try? await Task.sleep(for: .milliseconds(50))
    }
}

/// The only ways a capture test's fake may hold its thread.
enum Blocking {
    /// A request blocked in the framework: holds the thread until `released` holds, polling a millisecond a turn. **Only
    /// on a lane's own thread**, where the lane runs such a request; anywhere else the test records an issue, whether or
    /// not this run happened to have threads to spare.
    static func until(_ released: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        if !LaneThread.isCurrent {
            Issue.record("a fake blocked a thread that is not a lane's own: under load it may be one the release needs",
                         sourceLocation: sourceLocation)
        }
        while !released() { Thread.sleep(forTimeInterval: 0.001) }
    }

    /// A request that takes `duration`, and then answers: bounded, so it may run on any thread.
    static func `for`(_ duration: Duration) {
        Thread.sleep(forTimeInterval: duration / .seconds(1))
    }
}

/// An answer that never comes until the test opens it — a view that does not answer — awaited without holding a thread,
/// and deaf to cancellation, as a callback that never fires is.
final class Silence: Sendable {
    private let state = Mutex((open: false, waiting: [CheckedContinuation<Void, Never>]()))

    func wait() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiting.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state in
            state.open = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

extension AccessibilityLane {
    /// A lane for a test whose claim is order: no residence bound or overrun is reached in any run.
    static func patient(setTimeout: @escaping @Sendable (Float) -> Void) -> AccessibilityLane {
        AccessibilityLane(bounds: patientBounds, setTimeout: setTimeout)
    }

    static let patientBounds: LaneBounds = {
        guard let bounds = LaneBounds(explicitResidence: .seconds(3_600), hoverResidence: .seconds(3_600),
                                      overrun: .seconds(3_600)) else { preconditionFailure("positive bounds") }
        return bounds
    }()
}

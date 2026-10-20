import Foundation
import Synchronization
import Testing
import XDictCaptureMac

/// **A read blocked in the framework holds a thread of its lane's own, never one of Swift's cooperative pool** (2026-10-20).
/// The pool is as wide as the Mac has cores and must never be blocked: a read that waits on another app and cannot be
/// cancelled, run on it, takes a thread the rest of the process needs. Measured that day: lane tests' blocked reads and a
/// few long tests took all 17 of the pool's threads on the build Mac, and the whole capture suite stood still for 110 s,
/// the tests that would release those reads among those waiting.
struct LaneThreadTests {
    /// Twice as many lanes as the pool has threads, each with a read blocked in it: all are inside at once. Red while a
    /// lane's read runs on the pool, which holds at most its width of them until the release ends the run.
    @Test func blockedReadsLeaveTheCooperativePoolFree() async {
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let lanes = (0..<count).map { _ in AccessibilityLane.patient { _ in } }
        let inside = Mutex(0)
        let insideBeforeRelease = Mutex(0)
        let released = Mutex(false)
        // The release comes from a thread of its own, never the pool: once every read is inside, or at the patience, so a
        // red run ends rather than hangs.
        let releaser = Thread {
            let end = Date(timeIntervalSinceNow: Wait.patience / .seconds(1))
            while inside.withLock({ $0 }) < count, Date() < end { Blocking.for(.milliseconds(1)) }
            insideBeforeRelease.withLock { $0 = inside.withLock { $0 } }
            released.withLock { $0 = true }
        }
        releaser.start()
        let reads = lanes.map { lane in
            Task {
                await lane.submit(.explicit, timeout: 1, budget: .seconds(3_600)) { () -> Int in
                    inside.withLock { $0 += 1 }
                    Blocking.until { released.withLock { $0 } }
                    return 0
                }
            }
        }
        for read in reads { #expect(await read.value == .success(0)) }
        #expect(insideBeforeRelease.withLock { $0 } == count,
                "\(insideBeforeRelease.withLock { $0 }) of \(count) blocked reads ran at once: the rest waited for a thread")
    }
}

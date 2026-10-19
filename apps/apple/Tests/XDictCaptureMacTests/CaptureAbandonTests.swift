import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **A stalled capture is set aside once, never more** (owner, 2026-10-19: a first capture stalled in Vision's model load
/// refused every capture after it for its whole run). On a test clock: before `abandonAfter` a second capture is refused
/// as before; after it the stalled one is set aside and the next starts; while that one still runs no second is set
/// aside; its late release frees nothing of the new capture's; and once it ends, a stall may be set aside again.
struct CaptureAbandonTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { instant } }
        func advance(_ by: Duration) { lock.withLock { instant += by } }
    }

    private func guarded(_ clock: Clock) -> CaptureGuard {
        CaptureGuard(abandonAfter: .seconds(2), now: { clock.now })
    }

    @Test func aCaptureIsNotSetAsideBeforeTheBound() {
        let clock = Clock()
        let capture = guarded(clock)
        #expect(capture.claim() != nil)
        clock.advance(.milliseconds(1_999))
        #expect(capture.claim() == nil, "a capture held under the bound was set aside")
        #expect(!capture.holdsAbandoned)
    }

    @Test func aCaptureHeldPastTheBoundIsSetAsideAndTheNextStarts() throws {
        let clock = Clock()
        let capture = guarded(clock)
        let stalled = try #require(capture.claim())
        clock.advance(.seconds(2))
        let next = try #require(capture.claim(), "a stalled capture still refused the next")
        #expect(capture.holdsAbandoned)
        #expect(capture.isCurrent(next) && !capture.isCurrent(stalled))
    }

    @Test func neverMoreThanOneIsSetAside() throws {
        let clock = Clock()
        let capture = guarded(clock)
        _ = try #require(capture.claim())
        clock.advance(.seconds(3))
        let second = try #require(capture.claim())
        clock.advance(.seconds(3))
        #expect(capture.claim() == nil, "a second stalled capture was set aside while the first still runs")
        #expect(capture.isCurrent(second))
    }

    @Test func theSetAsideCapturesLateEndFreesNothingOfTheNext() throws {
        let clock = Clock()
        let capture = guarded(clock)
        let stalled = try #require(capture.claim())
        clock.advance(.seconds(2))
        let next = try #require(capture.claim())
        let (held, _) = capture.release(stalled)
        #expect(held == .seconds(2))
        #expect(!capture.holdsAbandoned)
        #expect(capture.isHeld && capture.isCurrent(next), "the stalled capture's end released the next one")
        #expect(capture.claim() == nil)
    }

    @Test func onceTheSetAsideCaptureEndsAStallMayBeSetAsideAgain() throws {
        let clock = Clock()
        let capture = guarded(clock)
        let stalled = try #require(capture.claim())
        clock.advance(.seconds(2))
        _ = try #require(capture.claim())
        capture.release(stalled)
        clock.advance(.seconds(2))
        #expect(capture.claim() != nil, "a later stall could not be set aside after the first one ended")
    }

    /// A wedge is reported for the capture in flight only, once.
    @Test func onlyTheCurrentCapturesWedgeIsReported() throws {
        let clock = Clock()
        let capture = guarded(clock)
        _ = try #require(capture.claim())
        clock.advance(.seconds(6))
        #expect(capture.overdue(after: .seconds(5)) == .seconds(6))
        #expect(capture.markReported())
        #expect(!capture.markReported())
        _ = try #require(capture.claim())
        #expect(capture.overdue(after: .seconds(5)) == nil, "the set-aside capture's wedge was counted as the new one's")
    }

    /// **One screenshot at a time, refused rather than started beside another** — the rule that keeps a capture set aside
    /// while blocked in ScreenCaptureKit from deadlocking the next.
    @Test func aSecondScreenshotIsRefusedUntilTheFirstReturns() {
        let gate = ScreenshotGate()
        #expect(gate.enter())
        #expect(!gate.enter(), "a second screenshot was started beside the first")
        gate.done()
        #expect(gate.enter())
    }
}

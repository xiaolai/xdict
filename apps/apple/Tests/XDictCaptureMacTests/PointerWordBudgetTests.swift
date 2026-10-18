import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
import XDictCaptureMac

/// **Hover's Accessibility read is bounded, and stops at the first failure** (moved by name from XiaolaiDict's
/// `AccessibilityBudgetTests`). It had a quarter-second timeout per request and nothing over the whole read, and
/// classified no failure, so an app that stopped answering was asked every remaining question. These count requests
/// rather than time them.
struct PointerWordBudgetTests {
    /// Counts requests, answers each with `status`, and advances a fake clock by `step` per request.
    final class Requests: Sendable {
        let made = Mutex(0)
        let status: AXError
        let step: Duration
        let origin = ContinuousClock.now
        let onRequest: @Sendable (Int) -> Void
        /// How many times the app was asked to build its tree for an assistive client.
        let enhanced = Mutex(0)

        init(status: AXError = .noValue, step: Duration = .zero, onRequest: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.status = status
            self.step = step
            self.onRequest = onRequest
        }

        var count: Int { made.withLock { $0 } }

        func now() -> ContinuousClock.Instant { origin + step * made.withLock { $0 } }

        var client: AccessibilityRequests {
            AccessibilityRequests(
                attribute: { _, _ in self.answer() },
                parameterized: { _, _, _ in self.answer() },
                // Chrome's own answer, measured: "not implemented" — while building the tree anyway.
                enhance: { _ in self.enhanced.withLock { $0 += 1 }; return .notImplemented })
        }

        private func answer() -> (AXError, CFTypeRef?) {
            let made = made.withLock { $0 += 1; return $0 }
            onRequest(made)
            return (status, nil)
        }

        func session(budget: Duration) -> AccessibilitySession {
            AccessibilitySession(budget: budget, now: { self.now() }, requests: client)
        }
    }

    /// An Accessibility target in an app that is not this one; the scripted session answers instead of it.
    static let target = PointerWordReader.Target(
        element: AXUIElementCreateApplication(getpid() + 1), appName: "TextEdit", bundleID: "com.apple.TextEdit")
    private static let point = CGPoint(x: 10, y: 10)

    private func read(_ session: AccessibilitySession, in target: PointerWordReader.Target = Self.target) -> PointerWordReader.Outcome {
        PointerWordReader.read(at: Self.point, in: target, tolerance: Measured.hit, with: session)
    }

    /// **The request after the budget is never made.** Each request costs 200 ms on the fake clock; against 500 ms the
    /// fourth is refused before it is sent.
    @Test func theRequestAfterTheBudgetIsNeverMade() {
        let requests = Requests(step: .milliseconds(200))
        let outcome = read(requests.session(budget: .milliseconds(500)))
        #expect(requests.count == 3, "made \(requests.count) requests against a three-request budget")
        #expect(outcome == .miss(.failed(.deadlineExceeded, app: "TextEdit")))
    }

    /// **Nothing is asked after `.notResponding`.** One unanswered request ends the hover read.
    @Test func nothingIsAskedAfterAnAppStopsAnswering() {
        let requests = Requests(status: .cannotComplete)
        let outcome = read(requests.session(budget: .seconds(60)))
        #expect(requests.count == 1, "asked \(requests.count) times after the app stopped answering")
        #expect(outcome == .miss(.failed(.notResponding, app: "TextEdit")))
    }

    /// **An absent value moves on; it does not end the read.** The control for the test above.
    @Test func anAbsentValueTriesTheNextDialect() {
        let requests = Requests(status: .noValue)
        _ = read(requests.session(budget: .seconds(60)))
        #expect(requests.count > 3, "an absent value ended the read after \(requests.count) requests")
    }

    /// **An app that does not answer the wake-up is asked nothing else**, and is woken again next time rather than
    /// remembered as woken.
    @Test func anUnansweredWakeUpEndsTheReadAndIsTriedAgain() {
        let requests = Requests(status: .noValue)
        let wakes = Mutex(0)
        var client = requests.client
        client.wake = { _ in wakes.withLock { $0 += 1 }; return .cannotComplete }
        let target = PointerWordReader.Target(element: AXUIElementCreateApplication(70_001), appName: "Hung", bundleID: "hung")
        let session = AccessibilitySession(budget: .seconds(60), now: { requests.now() }, requests: client)
        #expect(read(session, in: target) == .miss(.failed(.notResponding, app: "Hung")), "a hung app's wake-up did not end the read")
        #expect(requests.count == 0, "a hung app was asked \(requests.count) more questions")
        _ = read(session, in: target)
        #expect(wakes.withLock { $0 } == 2, "a wake-up that never went through was remembered")
    }

    /// **Every terminal wake-up answer ends the read, not only a timeout** — Accessibility off, the app gone — and none is
    /// remembered as a wake.
    @Test func aWakeUpRefusedForAnyReasonEndsTheRead() {
        for (status, failure) in [(AXError.apiDisabled, CaptureError.accessibilityDisabled), (.invalidUIElement, .appUnavailable)] {
            let requests = Requests(status: .noValue)
            var client = requests.client
            client.wake = { _ in status }
            let target = PointerWordReader.Target(element: AXUIElementCreateApplication(70_003), appName: "Gone", bundleID: "gone")
            let session = AccessibilitySession(budget: .seconds(60), now: { requests.now() }, requests: client)
            #expect(read(session, in: target) == .miss(.failed(failure, app: "Gone")), "a wake-up answered \(status.rawValue)")
            #expect(requests.count == 0)
        }
    }

    /// **Cancellation stops the read between requests.** The first request cancels the task making it; no second is
    /// sent, and the outcome says cancelled rather than missed.
    @Test func cancellationStopsBetweenRequests() async {
        let requests = Requests(status: .noValue) { made in
            if made == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let session = requests.session(budget: .seconds(60))
        let outcome = await Task.detached {
            PointerWordReader.read(at: CGPoint(x: 10, y: 10), in: Self.target, tolerance: Measured.hit, with: session)
        }.value
        #expect(requests.count == 1)
        #expect(outcome == .cancelled)
    }
}

/// **Chrome builds its page tree only for `AXEnhancedUserInterface`** (moved by name from XiaolaiDict's
/// `ChromiumEscalationTests`; measured there 2026-10-03: `AXManualAccessibility` is refused as unsupported). So a read
/// that found nothing asks once — never for an app that answers, never twice in one launch of it.
struct ChromiumEscalationTests {
    /// A pid nothing else in the suite uses, so the once-per-launch memory is this test's own.
    private static func target() -> PointerWordReader.Target {
        PointerWordReader.Target(
            element: AXUIElementCreateApplication(pid_t(4_000_000 + Int32.random(in: 0..<1_000_000))),
            appName: "Google Chrome", bundleID: "com.google.Chrome")
    }

    @Test func aFullMissAsksTheAppToBuildItsTreeOncePerLaunch() {
        let requests = PointerWordBudgetTests.Requests(status: .noValue)
        let target = Self.target()
        let first = PointerWordReader.read(at: CGPoint(x: 10, y: 10), in: target, tolerance: Measured.hit,
                                           with: requests.session(budget: .seconds(60)))
        guard case .miss(.noText) = first else { Issue.record("a read of an empty tree answered \(first)"); return }
        #expect(requests.enhanced.withLock { $0 } == 1, "a miss did not ask for the tree")
        _ = PointerWordReader.read(at: CGPoint(x: 10, y: 10), in: target, tolerance: Measured.hit,
                                   with: requests.session(budget: .seconds(60)))
        #expect(requests.enhanced.withLock { $0 } == 1, "the app was asked again in the same launch")
    }

    /// An app that stopped answering is not asked for more work.
    @Test func aReadThatFailedAsksNothingMore() {
        let requests = PointerWordBudgetTests.Requests(status: .cannotComplete)
        _ = PointerWordReader.read(at: CGPoint(x: 10, y: 10), in: Self.target(), tolerance: Measured.hit,
                                   with: requests.session(budget: .seconds(60)))
        #expect(requests.enhanced.withLock { $0 } == 0)
    }
}

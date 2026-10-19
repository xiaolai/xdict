import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **XDict's own Accessibility read is bounded per request and in total** (verifier, 2026-10-19). Measured on the build
/// Mac the same day: a main-thread hit test of XDict's own application over its own web view waited 1,530 ms (then
/// -25204); a messaging timeout set on that application element did not shorten it (1,513 ms); the process-wide timeout,
/// set on the system-wide element, did (0.25 s: 280 ms). So the own read is a lane job like any other — the lane, the one
/// owner of the process-wide timeout, sets the hover timeout before it and holds it while it runs — **run on the main
/// actor** (XiaolaiDict ADR-0042), and its session carries the hover budget.
///
/// The requests here stand in for Accessibility's: `Stall` answers each one after the time it was scripted to take, or
/// after the timeout the lane last set where that is shorter — failing it then, `cannotComplete`, as the framework does.
/// An unset timeout is the framework's default, six seconds.
@MainActor
@Suite(.serialized)
struct OwnReadBoundTests {
    private static let granted = AccessibilityAccess(probe: { .granted })
    private static let point = CGPoint(x: 5, y: 5)

    /// The process-wide timeout as the lane last set it, and every request's place against it.
    final class Stall: @unchecked Sendable {
        static let unsetTimeout: Float = 6
        let timeout = Mutex<Float>(Stall.unsetTimeout)
        /// Each event in order: "timeout 0.25", or "request" with whether it ran on the main thread.
        let events = Mutex<[String]>([])
        let hitTakes: Duration
        let attributeTakes: Duration

        init(hitTakes: Duration, attributeTakes: Duration = .zero) {
            self.hitTakes = hitTakes
            self.attributeTakes = attributeTakes
        }

        func set(_ value: Float) {
            timeout.withLock { $0 = value }
            events.withLock { $0.append("timeout \(value)") }
        }

        /// The longest any one request held its thread, and how many were made: counted, not clocked, so a test elsewhere
        /// holding the main actor cannot change them.
        let longest = Mutex<Duration>(.zero)
        let count = Mutex(0)

        /// Sleeps for `takes` or the timeout, whichever is shorter; false where the timeout cut it.
        private func wait(_ takes: Duration) -> Bool {
            events.withLock { $0.append(Thread.isMainThread ? "request" : "request off the main thread") }
            let limit = Duration.milliseconds(Int(timeout.withLock { $0 } * 1_000))
            let held = min(takes, limit)
            longest.withLock { $0 = max($0, held) }
            count.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: held / .seconds(1))
            return takes <= limit
        }

        /// An endless tree of XDict's own application: every element its own only child, every frame holding the point.
        var requests: AccessibilityRequests {
            AccessibilityRequests(
                attribute: { [self] element, name in
                    guard wait(attributeTakes) else { return (.cannotComplete, nil) }
                    switch name {
                    case kAXChildrenAttribute: return (.success, [element] as CFArray)
                    case kAXPositionAttribute:
                        var origin = CGPoint.zero
                        return (.success, AXValueCreate(.cgPoint, &origin))
                    case kAXSizeAttribute:
                        var size = CGSize(width: 1_000, height: 1_000)
                        return (.success, AXValueCreate(.cgSize, &size))
                    default: return (.noValue, nil)
                    }
                },
                parameterized: { [self] _, _, _ in
                    guard wait(attributeTakes) else { return (.cannotComplete, nil) }
                    return (.noValue, nil)
                },
                elementAt: { [self] _, _ in
                    guard wait(hitTakes) else { return (.cannotComplete, nil) }
                    return (.success, AXUIElementCreateApplication(getpid()))
                })
        }
    }

    private func source(_ stall: Stall) -> SystemPointerWords {
        let requests = stall.requests
        return SystemPointerWords(metrics: Measured.metrics, lane: AccessibilityLane { stall.set($0) }, access: Self.granted,
                                  client: { AccessibilitySession(budget: $0, requests: requests) })
    }

    /// **One stalled request is cut at the hover's messaging timeout**: XDict's own hit test, scripted to hang for three
    /// seconds, ends at a quarter of one, as not responding — the lane set the timeout before the first request, and the
    /// request ran on the main thread. Red where the own read leaves the timeout to whatever was set before it (the
    /// default six seconds here, so the hang runs its full three).
    @Test func aStalledOwnRequestIsCutAtTheHoverTimeout() async {
        let stall = Stall(hitTakes: .seconds(3))
        let outcome = await source(stall).ownTarget(at: Self.point)
        guard case .none(.failed(.notResponding)) = outcome else {
            Issue.record("got \(outcome)")
            return
        }
        let longest = stall.longest.withLock { $0 }
        #expect(longest <= PointerWordReader.messagingTimeoutDuration, "one request held the main actor for \(longest)")
        let events = stall.events.withLock { $0 }
        #expect(events.first == "timeout \(PointerWordReader.messagingTimeout)", "\(events)")
        #expect(!events.contains("request off the main thread"), "\(events)")
    }

    /// **The whole own read ends at its budget**, however many requests an endless tree invites: each answers in 30 ms,
    /// under the timeout, and the descent (24 levels, three requests each: 73 with the hit test, unbounded) stops at the
    /// hover budget, as past its deadline — about 17 requests. Red where the own read's session is given any other budget
    /// than the hover's.
    @Test func anEndlessOwnTreeIsCutAtTheHoverBudget() async {
        let stall = Stall(hitTakes: .milliseconds(30), attributeTakes: .milliseconds(30))
        let outcome = await source(stall).ownTarget(at: Self.point)
        let count = stall.count.withLock { $0 }
        guard case .none(.failed(.deadlineExceeded)) = outcome else {
            Issue.record("got \(outcome) after \(count) requests")
            return
        }
        #expect(count <= Int(PointerWordReader.budget / .milliseconds(30)) + 2, "\(count) requests")
    }

    /// **The own text read too**: under the budget it is handed — 150 ms of 100 ms requests is two — and the hover
    /// timeout set before its first request. Red where the read ignores the budget, or runs under a timeout it did not
    /// set.
    @Test func theOwnTextReadKeepsItsBudgetAndTimeout() async {
        let stall = Stall(hitTakes: .milliseconds(100), attributeTakes: .milliseconds(100))
        let target = PointerWordReader.Target(element: AXUIElementCreateApplication(getpid()), appName: "XDict",
                                              bundleID: "ai.xdict.app")
        let gated = await source(stall).readOwnUnlessRefused(at: Self.point, in: target, refuses: { _ in false },
                                                             budget: .milliseconds(150))
        let count = stall.count.withLock { $0 }
        #expect(count <= 2, "\(count) requests: \(gated)")
        let events = stall.events.withLock { $0 }
        #expect(events.first == "timeout \(PointerWordReader.messagingTimeout)", "\(events.prefix(3))")
        #expect(!events.contains("request off the main thread"))
    }

    /// **An own read waits its turn and holds the lane while it runs**: a hover of another app submitted while XDict's own
    /// read is in its request does not start until that read has returned, so nothing changes the timeout under it. Red
    /// where the own read runs beside the lane.
    @Test func nothingRunsBesideAnOwnRead() async {
        let order = Mutex<[String]>([])
        let lane = AccessibilityLane { _ in }
        // Off the main thread, which the own read holds: submitted once the own read is in its request.
        let other = Task.detached {
            while !order.withLock({ $0.contains("own starts") }) { try? await Task.sleep(for: .milliseconds(1)) }
            return await lane.submit(.explicit, timeout: 1, budget: .seconds(2)) { () -> Int in
                order.withLock { $0.append("other runs") }
                return 2
            }
        }
        _ = await lane.submitOnMainActor(.hover, timeout: 0.25, budget: .seconds(2)) { () -> Int in
            order.withLock { $0.append("own starts") }
            // A request in flight, long enough for the other read to be submitted beside it.
            Thread.sleep(forTimeInterval: 0.3)
            order.withLock { $0.append("own ends") }
            return 1
        }
        _ = await other.value
        #expect(order.withLock { $0 } == ["own starts", "own ends", "other runs"])
    }
}

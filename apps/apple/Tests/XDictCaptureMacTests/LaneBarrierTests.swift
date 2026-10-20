import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCaptureMac

/// **The rules a verifier's mutations showed untested** (plan-capture WI-2, second round): the order of a queue holding
/// both kinds, the blocked read kept as the barrier after its caller left, the caller let go at once, the deadline
/// before the hit test, and the clicked position carried into the read.
struct LaneBarrierTests {
    /// A read that ignores cancellation until released — a request inside the framework — counting reads inside.
    final class Held: Sendable {
        let started = Mutex(false)
        let release = Mutex(false)
        let inside = Mutex((now: 0, most: 0))
        func work() -> Int {
            enter()
            started.withLock { $0 = true }
            Blocking.until { release.withLock { $0 } }
            leave()
            return 0
        }
        func enter() { inside.withLock { $0.now += 1; $0.most = max($0.most, $0.now) } }
        func leave() { inside.withLock { $0.now -= 1 } }
    }

    /// **An explicit request queued before a hover runs before it.** Red if the queue starts the hover first.
    @Test func anExplicitRequestQueuedBeforeAHoverRunsFirst() async {
        let lane = AccessibilityLane.patient { _ in }
        let held = Held()
        let order = Mutex<[String]>([])
        let holding = Task { await lane.run(timeout: 1, { held.work() }, refused: { _ in -1 }) }
        #expect(await Wait.until { held.started.withLock { $0 } })
        let explicit = Task { await lane.submit(.explicit, timeout: 1, budget: .seconds(60)) { order.withLock { $0.append("explicit") }; return 1 } }
        #expect(await Wait.until { lane.queued().explicit == 1 })
        let hover = Task { await lane.submit(.hover, timeout: 0.25, budget: .seconds(60)) { order.withLock { $0.append("hover") }; return 2 } }
        #expect(await Wait.until { lane.queued().hover == 1 })
        held.release.withLock { $0 = true }
        _ = await holding.value
        _ = await explicit.value
        _ = await hover.value
        #expect(order.withLock { $0 } == ["explicit", "hover"])
    }

    /// **A blocked read whose caller cancelled stays the barrier**, and that caller is answered at once: while the read
    /// is held the lane still runs it, and the next read waits in the queue, not started. Red if cancelling clears the
    /// running read (the next is started at once; checked by the lane's state, since a lane's reads share one serial
    /// thread and so could never overlap anyway — verifier, 2026-10-20), or if the caller waits for its read.
    @Test func aCancelledBlockedReadStaysTheBarrierAndItsCallerIsLetGo() async {
        let lane = AccessibilityLane.patient { _ in }
        let held = Held()
        let blocked = Task { await lane.submit(.explicit, timeout: 1, budget: .seconds(60)) { held.work() } }
        #expect(await Wait.until { held.started.withLock { $0 } })
        blocked.cancel()
        #expect(await Wait.value(of: blocked) == .failure(.cancelled), "the cancelled caller waited for its read")
        let next = Task { await lane.submit(.explicit, timeout: 1, budget: .seconds(60)) { held.enter(); held.leave(); return 1 } }
        #expect(await Wait.until { lane.queued().explicit == 1 }, "the next read was not left waiting behind the blocked one")
        #expect(lane.current() == .running(.explicit), "the lane let go of the blocked read: \(lane.current())")
        held.release.withLock { $0 = true }
        #expect(await next.value == .success(1))
        #expect(held.inside.withLock { $0.most } == 1, "a read ran beside the blocked one")
    }

    /// **A blocked hover superseded by an explicit request stays the barrier**: while the hover's request is held the
    /// lane still runs the hover, and the explicit read waits in the queue, not started. Red if superseding clears the
    /// running read (checked by the lane's state, as above).
    @Test func aSupersededBlockedHoverStaysTheBarrier() async {
        let lane = AccessibilityLane.patient { _ in }
        let held = Held()
        let hover = Task { await lane.submit(.hover, timeout: 0.25, budget: .seconds(60)) { held.work() } }
        #expect(await Wait.until { held.started.withLock { $0 } })
        let explicit = Task { await lane.submit(.explicit, timeout: 1, budget: .seconds(60)) { held.enter(); held.leave(); return 1 } }
        #expect(await Wait.value(of: hover) == .failure(.superseded))
        #expect(lane.queued().explicit == 1, "the explicit read was not left waiting behind the blocked hover")
        #expect(lane.current() == .running(.hover), "the lane let go of the blocked hover: \(lane.current())")
        held.release.withLock { $0 = true }
        #expect(await explicit.value == .success(1))
        #expect(held.inside.withLock { $0.most } == 1, "the explicit read ran beside the blocked hover")
    }

    /// **The deadline is checked before the hit test is made**: a spent budget sends no hit test at all. Red if only the
    /// check after it remains.
    @Test func aSpentBudgetSendsNoHitTest() {
        let asked = Mutex(0)
        let session = AccessibilitySession(budget: .zero, requests: AccessibilityRequests(
            attribute: { _, _ in (.noValue, nil) }, parameterized: { _, _, _ in (.noValue, nil) },
            elementAt: { _, _ in asked.withLock { $0 += 1 }; return (.noValue, nil) }))
        #expect(throws: CaptureError.deadlineExceeded) { try session.hitTest(AXUIElementCreateApplication(91_200), at: .zero) }
        #expect(asked.withLock { $0 } == 0, "a hit test was sent with the budget spent")
    }

    /// **The clicked position reaches the read made on the lane**: the element under it holds the selection. Red if the
    /// read is made without it.
    @Test func theClickedPositionReachesTheReadOnTheLane() async {
        let lane = AccessibilityLane.patient { _ in }
        // The fake's application element is process 90000's, so the read must be of that process.
        let app = FrontApp(pid: 90_000, name: "Reader", bundleID: "com.example.reader")
        let clicked = CGPoint(x: 440, y: 150)
        let outcome = await SelectionReader.read(
            from: app, clicked: clicked, admitting: SelectionReaderTests.admission, excluding: SelectionReaderTests.exclusions,
            access: AccessibilityAccess(probe: { .granted }), lane: lane,
            client: { _ in
                let tree = FakeAccessibility()
                let view = tree.element(2)
                tree.set(view, kAXSelectedTextAttribute, "ephemeral" as CFString)
                tree.hit(clicked, view)
                return tree
            }, ownHolder: { .controls })
        guard case .selected(let selected, _) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(selected.text == "ephemeral")
    }
}

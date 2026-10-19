import Foundation
import Synchronization
import Testing
import XDictCaptureMac

/// **One out-of-process Accessibility read at a time, each under its own timeout** (moved from XiaolaiDict's
/// `AccessibilityLaneTests`), **and the rules a FIFO lacked** (XDict ADR-0014 decision 6): explicit before hover, hover
/// coalesced, residence bounded, a blocked read reported. No test touches the real Accessibility API: the work is a
/// closure, the process-wide timeout a fake setter.
struct AccessibilityLaneTests {
    /// Reads started together never overlap. Red if the lane stops waiting for the read in flight.
    @Test func readsNeverOverlap() async {
        let lane = AccessibilityLane { _ in }
        let running = Mutex((now: 0, most: 0))
        await withTaskGroup(of: Int.self) { group in
            for index in 0..<5 {
                group.addTask {
                    await lane.run(timeout: 1, {
                        running.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
                        Thread.sleep(forTimeInterval: 0.02)  // a request nothing can interrupt
                        running.withLock { $0.now -= 1 }
                        return index
                    }, refused: { _ in -1 })
                }
            }
            for await _ in group {}
        }
        #expect(running.withLock { $0.most } == 1, "two Accessibility reads ran side by side")
    }

    /// **Each read sees its own timeout.** Hover's quarter second and a selection read's full second are set on entry, so
    /// neither changes the other's mid-read.
    @Test func eachReadSeesItsOwnTimeout() async {
        let current = Mutex<Float>(0)
        let lane = AccessibilityLane { value in current.withLock { $0 = value } }
        let seen = await withTaskGroup(of: (Float, Float).self) { group in
            for timeout: Float in [0.25, 1.0, 0.25, 1.0] {
                group.addTask {
                    await lane.run(timeout: timeout, {
                        Thread.sleep(forTimeInterval: 0.01)
                        return (timeout, current.withLock { $0 })
                    }, refused: { _ in (timeout, -1) })
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(seen.count == 4)
        for (asked, saw) in seen { #expect(asked == saw, "a read asked for \(asked) ran under \(saw)") }
    }

    /// A read whose caller gave up before its turn does no work.
    @Test func aReadCancelledBeforeItsTurnDoesNoWork() async {
        let lane = AccessibilityLane { _ in }
        let worked = Mutex(0)
        let started = Mutex(false)
        let blocker = Task {
            await lane.run(timeout: 1, {
                started.withLock { $0 = true }
                Thread.sleep(forTimeInterval: 0.05)
                return 0
            }, refused: { _ in -1 })
        }
        #expect(await Wait.until { started.withLock { $0 } })
        let waiting = Task { await lane.run(timeout: 1, { worked.withLock { $0 += 1 }; return 1 }, refused: { _ in -1 }) }
        waiting.cancel()
        #expect(await waiting.value == -1)
        _ = await blocker.value
        await Wait.drain()
        #expect(worked.withLock { $0 } == 0)
    }

    /// **A cancelled caller is let go at once**, not after the read ahead of it. Bounded, so a regression fails rather
    /// than hangs: the read ahead is released only after this.
    @Test func aCancelledWaiterIsAnsweredBeforeTheReadAheadEnds() async {
        let lane = AccessibilityLane { _ in }
        let started = Mutex(false)
        let release = Mutex(false)
        let blocker = Task {
            await lane.run(timeout: 1, {
                started.withLock { $0 = true }
                while !release.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
                return 0
            }, refused: { _ in -1 })
        }
        #expect(await Wait.until { started.withLock { $0 } })
        let waiting = Task { await lane.submit(.explicit, timeout: 1, budget: .seconds(60)) { 1 } }
        waiting.cancel()
        let answered = await Wait.value(of: waiting)
        #expect(answered == .failure(.cancelled), "a cancelled caller waited for the read ahead of it")
        release.withLock { $0 = true }
        _ = await blocker.value
    }

    /// **A caller cancelled before it asks does no work**, even on an idle lane.
    @Test func aCallerCancelledBeforeAskingDoesNoWork() async {
        let lane = AccessibilityLane { _ in }
        let worked = Mutex(0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await lane.run(timeout: 1, { worked.withLock { $0 += 1 }; return 1 }, refused: { _ in -1 })
        }
        #expect(await task.value == -1)
        await Wait.drain()
        #expect(worked.withLock { $0 } == 0, "a cancelled caller's read ran")
    }
}

/// **The rules of decision 6**, each against the defect it exists for.
struct AccessibilityLaneRuleTests {
    /// A read that holds the lane until released, and says when it has started.
    final class Blocker: Sendable {
        let started = Mutex(false)
        let release = Mutex(false)
        func work() -> Int {
            started.withLock { $0 = true }
            while !release.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
            return 0
        }
    }

    /// **A hover flood, then the shortcut: the shortcut waits only for the read in flight, and no stale hover runs after
    /// it.** Fifty hovers queue behind a read; each replaces the last, and the explicit read that follows makes the one
    /// left stale. Once the read in flight is released the shortcut's read starts within the specified bound — a FIFO lane
    /// made it wait for every hover ahead, a quarter second each against a hung app — and not one hover executes, then or
    /// later. Red without coalescing (fifty answered late or run), without priority (the hover runs first) or without the
    /// staleness rule (the last hover runs after the shortcut).
    @Test func aHoverFloodThenAShortcutReadWaitsOnlyForTheReadInFlight() async {
        let lane = AccessibilityLane { _ in }
        let blocker = Blocker()
        let hoversRun = Mutex(0)
        let holding = Task { await lane.run(timeout: 1, { blocker.work() }, refused: { _ in -1 }) }
        #expect(await Wait.until { blocker.started.withLock { $0 } })
        let answered = Mutex(0)
        let hovers = (0..<50).map { _ in
            Task {
                let outcome = await lane.submit(.hover, timeout: 0.25, budget: .milliseconds(500)) {
                    hoversRun.withLock { $0 += 1 }
                    return 0
                }
                answered.withLock { $0 += 1 }
                return outcome
            }
        }
        let asked = Mutex<ContinuousClock.Instant?>(nil)
        let started = Mutex<ContinuousClock.Instant?>(nil)
        // Every hover is queued before the shortcut, as the pointer's flood precedes the press: forty-nine replaced,
        // one waiting.
        #expect(await Wait.until { answered.withLock { $0 } == 49 && lane.queued().hover == 1 })
        let shortcut = Task {
            asked.withLock { $0 = .now }
            return await lane.submit(.explicit, timeout: 1, budget: .seconds(2)) { started.withLock { $0 = .now }; return 7 }
        }
        #expect(await Wait.until { asked.withLock { $0 } != nil })
        blocker.release.withLock { $0 = true }
        #expect(await shortcut.value == .success(7))
        _ = await holding.value
        for hover in hovers { #expect(await hover.value == .failure(.superseded)) }
        await Wait.drain()
        #expect(hoversRun.withLock { $0 } == 0, "a stale hover executed")
        if let asked = asked.withLock({ $0 }), let started = started.withLock({ $0 }) {
            #expect(started - asked < Self.maximumShortcutWait, "the shortcut waited \(started - asked) behind hover work")
        }
    }

    /// The shortcut's wait behind the read in flight, past that read's release: scheduling only. A lane that ran one
    /// queued hover first adds that hover's work; one that ran all fifty adds fifty.
    static let maximumShortcutWait: Duration = .milliseconds(500)

    /// **A newer hover replaces the one waiting**: the older is answered `superseded` at once and never run; the newer
    /// runs. Red if hover work queues in order.
    @Test func aNewerHoverReplacesTheOneWaiting() async {
        let lane = AccessibilityLane { _ in }
        let blocker = Blocker()
        let ran = Mutex<[Int]>([])
        let holding = Task { await lane.run(timeout: 1, { blocker.work() }, refused: { _ in -1 }) }
        #expect(await Wait.until { blocker.started.withLock { $0 } })
        let older = Task {
            await lane.submit(.hover, timeout: 0.25, budget: .seconds(60)) { ran.withLock { $0.append(1) }; return 1 }
        }
        #expect(await Wait.until { lane.queued().hover == 1 })
        let newer = Task {
            await lane.submit(.hover, timeout: 0.25, budget: .seconds(60)) { ran.withLock { $0.append(2) }; return 2 }
        }
        #expect(await Wait.value(of: older) == .failure(.superseded))
        blocker.release.withLock { $0 = true }
        #expect(await newer.value == .success(2))
        _ = await holding.value
        #expect(ran.withLock { $0 } == [2])
    }

    /// **An explicit request stops the hover in flight between its requests**, and the hover's caller is answered at once:
    /// the running hover is stale. Red if an explicit request waits for a hover to run to its budget.
    @Test func anExplicitRequestStopsTheHoverInFlight() async {
        let lane = AccessibilityLane { _ in }
        let started = Mutex(false)
        let sawCancellation = Mutex(false)
        let hover = Task {
            await lane.submit(.hover, timeout: 0.25, budget: .seconds(60)) {
                started.withLock { $0 = true }
                // A hover's bounds scan: one request after another, each checking the reader still wants it.
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
                sawCancellation.withLock { $0 = true }
                return 0
            }
        }
        #expect(await Wait.until { started.withLock { $0 } })
        // Bounded, so a lane that waits for the hover fails rather than hangs: this hover never ends on its own.
        let shortcut = await Wait.value(of: Task { await lane.submit(.explicit, timeout: 1, budget: .seconds(2)) { 3 } })
        #expect(shortcut == .success(3))
        #expect(await Wait.value(of: hover) == .failure(.superseded))
        #expect(await Wait.until { sawCancellation.withLock { $0 } }, "the stale hover was not told to stop")
        hover.cancel()
    }

    /// **Residence is bounded as well as execution**: a hover that waited past its bound behind a slow — not stuck — read
    /// is dropped with `overstayed`, never run. Red if the queue keeps an item however long it waits.
    @Test func anItemThatWaitsTooLongIsDroppedWithItsOutcome() async throws {
        let bounds = try #require(LaneBounds(explicitResidence: .seconds(5), hoverResidence: .milliseconds(40),
                                             overrun: .seconds(60)))
        let lane = AccessibilityLane(bounds: bounds) { _ in }
        let blocker = Blocker()
        let ran = Mutex(false)
        let holding = Task { await lane.run(timeout: 1, budget: .seconds(60), { blocker.work() }, refused: { _ in -1 }) }
        #expect(await Wait.until { blocker.started.withLock { $0 } })
        let hover = Task {
            await lane.submit(.hover, timeout: 0.25, budget: .seconds(60)) { ran.withLock { $0 = true }; return 1 }
        }
        let outcome = await Wait.value(of: hover)
        guard case .failure(.overstayed(let waited))? = outcome else {
            Issue.record("a hover past its residence answered \(String(describing: outcome))")
            blocker.release.withLock { $0 = true }
            return
        }
        #expect(waited >= .milliseconds(40))
        blocker.release.withLock { $0 = true }
        _ = await holding.value
        await Wait.drain()
        #expect(!ran.withLock { $0 }, "a hover dropped from the queue ran anyway")
    }

    /// **A call blocked in the framework is reported, not hidden.** A read whose one request outlasts its budget and the
    /// overrun answers its caller `stuck`, the lane says it is stuck, an explicit request queued behind it is answered
    /// `stuck` at its residence bound, and the blocked read still holds the lane — nothing runs beside it — until its
    /// request returns, after which the lane serves again. Red if a stuck read is waited on silently.
    @Test func aReadBlockedInTheFrameworkIsReportedStuck() async throws {
        let bounds = try #require(LaneBounds(explicitResidence: .milliseconds(120), hoverResidence: .milliseconds(120),
                                             overrun: .milliseconds(30)))
        let lane = AccessibilityLane(bounds: bounds) { _ in }
        let release = Mutex(false)
        let inside = Mutex(0)
        let blocked = Task {
            await lane.submit(.explicit, timeout: 1, budget: .milliseconds(30)) {
                inside.withLock { $0 += 1 }
                // A request that does not return: no budget check between requests can reach it.
                while !release.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.001) }
                inside.withLock { $0 -= 1 }
                return 0
            }
        }
        let first = await Wait.value(of: blocked)
        guard case .failure(.stuck)? = first else {
            Issue.record("a blocked read answered \(String(describing: first))")
            release.withLock { $0 = true }
            return
        }
        guard case .stuck(.explicit, _) = lane.current() else {
            Issue.record("the lane says \(lane.current()) while blocked")
            release.withLock { $0 = true }
            return
        }
        let behind = await Wait.value(of: Task {
            await lane.submit(.explicit, timeout: 1, budget: .seconds(2)) { inside.withLock { $0 } }
        })
        guard case .failure(.stuck)? = behind else {
            Issue.record("a read behind the blocked one answered \(String(describing: behind))")
            release.withLock { $0 = true }
            return
        }
        release.withLock { $0 = true }
        #expect(await Wait.until { lane.current() == .idle })
        #expect(await lane.submit(.explicit, timeout: 1, budget: .seconds(2)) { inside.withLock { $0 } } == .success(0),
                "the lane did not serve again once the blocked request returned, or ran beside it")
    }

    @Test func boundsThatDropEverythingAreRefused() {
        #expect(LaneBounds(explicitResidence: .zero, hoverResidence: .seconds(1), overrun: .seconds(1)) == nil)
        #expect(LaneBounds(explicitResidence: .seconds(1), hoverResidence: .seconds(1), overrun: .seconds(-1)) == nil)
    }
}

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

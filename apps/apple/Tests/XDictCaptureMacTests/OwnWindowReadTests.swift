import AppKit
import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// XDict's own window as Accessibility would answer it in this process: the hit test names an element of this process,
/// whose text is `Glyphs`' ("cat" at x 310…340, y 200…220). **Every request records whether it ran on the main thread**,
/// and which root each hit test was asked of (0 for the system-wide element).
final class OwnWindowTree: AccessibilityReading, @unchecked Sendable {
    static let text = "Quokka sentinel 7741 cat whispers."
    private let glyphs = Glyphs(OwnWindowTree.text, speaksTextRange: true)
    private let lock = NSLock()
    private var requestCount = 0
    private var offMainCount = 0
    private var rootList: [pid_t] = []
    private var wakeCount = 0

    var requests: Int { lock.withLock { requestCount } }
    var offMain: Int { lock.withLock { offMainCount } }
    var roots: [pid_t] { lock.withLock { rootList } }
    var woken: Int { lock.withLock { wakeCount } }

    private func note() {
        let main = Thread.isMainThread
        lock.withLock {
            requestCount += 1
            if !main { offMainCount += 1 }
        }
    }

    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
        note()
        if name == kAXChildrenAttribute { return [] as CFArray }
        // One read at a time asks this tree, so `Glyphs`' own count needs no lock.
        return try glyphs.attribute(element, name, ofApplication: ofApplication)
    }

    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        note()
        return try glyphs.parameterized(element, name, argument)
    }

    func hitTest(_ root: AXUIElement, at point: CGPoint) throws(CaptureError) -> AXUIElement? {
        note()
        var pid: pid_t = 0
        if root != AXUIElementCreateSystemWide() { AXUIElementGetPid(root, &pid) }
        lock.withLock { rootList.append(pid) }
        return AXUIElementCreateApplication(getpid())
    }

    func wake(_ application: AXUIElement) throws(CaptureError) {
        note()
        lock.withLock { wakeCount += 1 }
    }

    func enhance(_ application: AXUIElement) throws(CaptureError) {
        note()
        lock.withLock { wakeCount += 1 }
    }
}

/// **Hover reads XDict's own windows, on the main actor** (owner, 2026-10-19: hover works in the main window, the entry
/// view, Settings and the popover; the hold key or the double tap is what asks, so the popover cannot re-trigger itself).
/// The hazard XiaolaiDict ADR-0042 named is an Accessibility request about this process made off the main thread: it is
/// serviced in-process on the calling thread. So the real source asks XDict's own application on the main actor, under the
/// same budget and limits, and **never through the lane** — whose thread the main actor would otherwise wait on.
@MainActor
struct OwnWindowReadTests {
    private static let granted = AccessibilityAccess(probe: { .granted })
    private static let cat = CGPoint(x: 325, y: 210)

    /// **The real source: the hit test and the combined read of XDict's own window run on the main thread, and the lane is
    /// never entered** (it sets the messaging timeout on entry, so a lane job would be seen). The hit test is asked of
    /// XDict's own application, not the system-wide element; no Chromium wake is asked of XDict itself. Red if either half
    /// goes through the lane or off the main thread.
    @Test func theRealSourceReadsOurOwnWindowOnTheMainThreadAndNeverEntersTheLane() throws {
        let timeouts = Mutex<[Float]>([])
        let lane = AccessibilityLane { timeout in timeouts.withLock { $0.append(timeout) } }
        let tree = OwnWindowTree()
        let source = SystemPointerWords(metrics: Measured.metrics, lane: lane, access: Self.granted, client: { _ in tree })
        guard case .found(let target) = source.ownTarget(at: Self.cat) else {
            Issue.record("XDict's own window named no target")
            return
        }
        #expect(target.pid == getpid())
        #expect(tree.roots == [getpid()], "the own hit test was not asked of XDict's own application")
        let gated = source.readOwnUnlessRefused(at: Self.cat, in: target, refuses: { HoverPolicy.shipped.refuses($0) },
                                                budget: PointerWordReader.budget)
        guard case .read(.hit(let hit)) = gated else {
            Issue.record("got \(gated)")
            return
        }
        #expect(hit.word.word == "cat")
        #expect(tree.requests > 0 && tree.offMain == 0, "\(tree.offMain) of \(tree.requests) requests ran off the main thread")
        #expect(timeouts.withLock { $0 }.isEmpty, "XDict's own read went through the lane")
        #expect(tree.woken == 0, "XDict asked itself to build its tree for an assistive client")
    }

    /// **The main actor never waits on the lane for XDict's own window**: with the lane held by a stalled read, a hover over
    /// XDict's own window still reads its word, sooner than a hover may wait in the lane at all (a hover queued behind the
    /// stall would be answered `overstayed` at its residence bound, with no word). Red if any part of the own read is a
    /// lane job.
    @Test func ourOwnWindowIsReadWhileTheLaneIsStalled() async {
        let lane = AccessibilityLane { _ in }
        let gate = DispatchSemaphore(value: 0)
        let stalled = Task.detached {
            await lane.submit(.explicit, timeout: 1, budget: .seconds(30)) { () -> Int in
                gate.wait()
                return 0
            }
        }
        await HoverFixtures.settle { lane.current() == .running(.explicit) }
        let tree = OwnWindowTree()
        let ours = ListedWindow(pid: getpid(), bounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_000), windowID: 3)
        let source = SystemPointerWords(metrics: Measured.metrics, lane: lane, access: Self.granted, windows: { [ours] },
                                        client: { _ in tree })
        let reader = HoverReader(policy: { .shipped }, source: source, contexts: PendingContexts())
        let started = ContinuousClock.now
        let outcome = await reader.read(at: Self.cat, modifiersHeld: [.option], tappedTwice: false,
                                        pointerStillFor: .seconds(1),
                                        begin: { CaptureRequest(number: 3, trigger: .pointerGesture) })
        let took = ContinuousClock.now - started
        #expect(lane.current() == .running(.explicit), "the stall ended before the own read was checked")
        gate.signal()
        _ = await stalled.value
        guard case .word(let hit, _, _) = outcome else {
            Issue.record("got \(outcome)")
            return
        }
        #expect(hit.word.word == "cat")
        #expect(took < LaneBounds.shipped.hoverResidence, "the own read took \(took), as long as a wait in the lane")
        #expect(tree.offMain == 0)
    }

    /// **A miss in XDict's own window asks XDict nothing more**: the Chromium wake-up and escalation an app that answered
    /// nothing gets are never asked of this process. Red without the guard in either.
    @Test func aMissInOurOwnWindowAsksNoWakeUp() {
        let tree = OwnWindowTree()
        let source = SystemPointerWords(metrics: Measured.metrics, lane: AccessibilityLane { _ in }, access: Self.granted,
                                        client: { _ in tree })
        guard case .found(let target) = source.ownTarget(at: Self.cat) else {
            Issue.record("no target")
            return
        }
        let gated = source.readOwnUnlessRefused(at: CGPoint(x: 900, y: 600), in: target,
                                                refuses: { HoverPolicy.shipped.refuses($0) },
                                                budget: PointerWordReader.budget)
        guard case .read(.miss) = gated else {
            Issue.record("got \(gated)")
            return
        }
        #expect(tree.woken == 0, "XDict asked itself to wake or build its tree")
    }

    /// **XDict excluded by the reader: refused before any request about XDict is made**, through the real source — not
    /// the hit test, not a read (the reader's own "Never look up in" list; owner, 2026-10-19).
    @Test func anExcludedXDictIsAskedNothing() async {
        let tree = OwnWindowTree()
        let ours = ListedWindow(pid: getpid(), bounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_000), windowID: 3)
        let source = SystemPointerWords(metrics: Measured.metrics, lane: AccessibilityLane { _ in }, access: Self.granted,
                                        windows: { [ours] }, client: { _ in tree })
        var policy = HoverPolicy.shipped
        policy.excludedApps.insert("ai.xdict.app")
        let excluding = policy
        let reader = HoverReader(policy: { excluding }, source: source, contexts: PendingContexts(),
                                 ownBundleID: "ai.xdict.app")
        let outcome = await reader.read(at: Self.cat, modifiersHeld: [.option], tappedTwice: false,
                                        pointerStillFor: .seconds(1),
                                        begin: { CaptureRequest(number: 4, trigger: .pointerGesture) })
        guard case .quiet(.excludedApp) = outcome else {
            Issue.record("got \(outcome)")
            return
        }
        #expect(tree.requests == 0, "\(tree.requests) requests were made about an excluded XDict")
    }

    /// **A click-through window of XDict's is told by the window itself** — the hover notice and the popover's anchor take
    /// no click (`ignoresMouseEvents`) and carry no reader text — and an ordinary window of XDict's is not one.
    @Test func aWindowThatTakesNoClickPassesClicksThrough() throws {
        _ = NSApplication.shared
        let notice = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        notice.ignoresMouseEvents = true
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        defer {
            notice.close()
            window.close()
        }
        try #require(notice.windowNumber > 0 && window.windowNumber > 0)
        let windows = [window, notice]
        #expect(HoverReader.passesClicksThrough(UInt32(notice.windowNumber), among: windows))
        #expect(!HoverReader.passesClicksThrough(UInt32(window.windowNumber), among: windows))
        #expect(!HoverReader.passesClicksThrough(0, among: windows), "a window that is not XDict's was taken for one")
    }
}

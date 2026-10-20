import ApplicationServices
import Foundation
import Synchronization
import Testing
@testable import XDictCaptureMac

/// **One read's requests, classified and bounded** (moved from XiaolaiDict's `CaptureTests` and `BreadthFirstTests`, in
/// `SelectionTests.swift`): every status that needs its own answer kept apart, and the hit test inside the budget (XDict
/// ADR-0014 decision 6). The raw requests are a seam: no test reaches the real Accessibility API.
struct AccessibilitySessionTests {
    /// Found by audit: every Accessibility error became "nothing selected". The ones that need a different answer for the
    /// reader are kept apart.
    @Test(arguments: [
        (AXError.success, AccessibilitySession.Answer.value),
        (.noValue, .absent), (.attributeUnsupported, .absent), (.failure, .absent),
        (.cannotComplete, .failed(.notResponding)), (.apiDisabled, .failed(.accessibilityDisabled)),
        (.invalidUIElement, .absent),
    ])
    func accessibilityStatusesAreClassified(status: AXError, answer: AccessibilitySession.Answer) {
        #expect(AccessibilitySession.answer(for: status) == answer)
    }

    @Test func anInvalidApplicationElementMeansTheAppIsGone() {
        #expect(AccessibilitySession.answer(for: .invalidUIElement, ofApplication: true) == .failed(.appUnavailable))
    }

    /// A locked screen answers kAXErrorFailure (-25200) for the app itself — "is the screen locked?", not "nothing
    /// selected". Deeper in the tree the same status only means that element had nothing.
    @Test func aRefusalByTheAppItselfIsReported() {
        #expect(AccessibilitySession.answer(for: .failure, ofApplication: true) == .failed(.accessibilityRefused))
        #expect(AccessibilitySession.answer(for: .failure) == .absent)
    }

    /// **A stalled hit test cannot spend the rest of the read.** The hit test is a request of the session: checked
    /// against the deadline before it is made, and its answer not believed when it came back after the deadline — so a
    /// hit test that blocked past the budget ends the read as `deadlineExceeded`, and the request after it is never
    /// made. Before this target XDict hit-tested the clicked position before its session existed, with no bound at all.
    @Test func aStalledHitTestEndsTheReadAtItsDeadline() {
        let asked = Mutex(0)
        let requests = AccessibilityRequests(
            attribute: { _, _ in asked.withLock { $0 += 1 }; return (.noValue, nil) },
            parameterized: { _, _, _ in asked.withLock { $0 += 1 }; return (.noValue, nil) },
            elementAt: { root, _ in
                Blocking.for(.milliseconds(80))  // blocked in the framework past the budget
                return (.success, root)
            })
        let session = AccessibilitySession(budget: .milliseconds(20), requests: requests)
        let application = AXUIElementCreateApplication(91_001)
        #expect(throws: CaptureError.deadlineExceeded) { try session.hitTest(application, at: CGPoint(x: 5, y: 5)) }
        #expect(throws: CaptureError.deadlineExceeded) { try session.attribute(application, kAXRoleAttribute, ofApplication: true) }
        #expect(asked.withLock { $0 } == 0, "a request was made after the budget was spent")
    }

    /// The control: a hit test inside the budget answers its element, and a hung app's hit test ends the read as not
    /// responding rather than as nothing there.
    @Test func aHitTestInsideTheBudgetIsAnswered() throws {
        let application = AXUIElementCreateApplication(91_002)
        let found = AXUIElementCreateApplication(91_003)
        let answering = AccessibilitySession(budget: .seconds(60), requests: AccessibilityRequests(
            attribute: { _, _ in (.noValue, nil) }, parameterized: { _, _, _ in (.noValue, nil) },
            elementAt: { _, _ in (.success, AXUIElementCreateApplication(91_003)) }))
        #expect(try answering.hitTest(application, at: .zero) == found)
        let hung = AccessibilitySession(budget: .seconds(60), requests: AccessibilityRequests(
            attribute: { _, _ in (.noValue, nil) }, parameterized: { _, _, _ in (.noValue, nil) },
            elementAt: { _, _ in (.cannotComplete, nil) }))
        #expect(throws: CaptureError.notResponding) { try hung.hitTest(application, at: .zero) }
    }
}

struct BreadthFirstTests {
    private let graph: [Int: [Int]] = [0: [1, 2], 1: [3, 0], 2: [3], 3: [4], 4: []]

    @Test func findsAMatch() {
        guard case .found(3) = breadthFirst(from: 0, limit: 10, children: { graph[$0] ?? [] }, matches: { $0 == 3 }) else {
            Issue.record("expected to find 3")
            return
        }
    }

    /// Cycles and shared children are visited once, so they cannot use up the limit.
    @Test func eachNodeIsVisitedOnce() {
        var visits: [Int] = []
        _ = breadthFirst(from: 0, limit: 10, children: { graph[$0] ?? [] }, matches: { visits.append($0); return false })
        #expect(visits == [0, 1, 2, 3, 4])
    }

    /// Running out of budget is not the same as finding nothing.
    @Test func runningOutOfBudgetIsReportedAsSuch() {
        guard case .limitReached = breadthFirst(from: 0, limit: 2, children: { graph[$0] ?? [] }, matches: { $0 == 4 }) else {
            Issue.record("expected the limit to be reported")
            return
        }
        guard case .absent = breadthFirst(from: 0, limit: 10, children: { graph[$0] ?? [] }, matches: { $0 == 9 }) else {
            Issue.record("expected absence")
            return
        }
    }
}

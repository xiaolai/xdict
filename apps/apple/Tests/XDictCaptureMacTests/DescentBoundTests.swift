import ApplicationServices
import Foundation
import Testing
@testable import XDictCaptureMac

/// **The descent from an app's own hit test is bounded by its own limits, in requests and in time** (verifier,
/// 2026-10-19: with the two limits removed no test failed, and with only the child limit gone a fan-out case ran past
/// 18 minutes). Each hostile tree here stands in for an app's: a fan-out of 10,000 children, an element that is its own
/// child, an endless chain. The tree acts as a budget of its own — past `requestCap` requests or `timeCap` it fails the
/// read, as the real session's budget would — so a missing limit turns a test red at once instead of hanging the suite.
struct DescentBoundTests {
    final class Hostile: AccessibilityReading, @unchecked Sendable {
        enum Shape { case fanOut, selfCycle, chain }
        static let requestCap = 5_000
        static let timeCap: Duration = .seconds(2)
        static let rootPid: pid_t = 4_500_000
        let shape: Shape
        let root = AXUIElementCreateApplication(Hostile.rootPid)
        private let started = ContinuousClock.now
        private(set) var requests = 0
        private(set) var overBudget = false

        init(_ shape: Shape) { self.shape = shape }

        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            requests += 1
            guard requests <= Self.requestCap, ContinuousClock.now - started < Self.timeCap else {
                overBudget = true
                throw .deadlineExceeded
            }
            switch name {
            case kAXChildrenAttribute:
                switch shape {
                case .fanOut: return (0..<10_000).map { AXUIElementCreateApplication(4_600_000 + Int32($0)) } as CFArray
                case .selfCycle: return [element] as CFArray
                case .chain:
                    var pid: pid_t = 0
                    AXUIElementGetPid(element, &pid)
                    return [AXUIElementCreateApplication(pid + 1)] as CFArray
                }
            case kAXPositionAttribute:
                var origin = CGPoint.zero
                return AXValueCreate(.cgPoint, &origin)
            case kAXSizeAttribute:
                var size = CGSize(width: 1_000, height: 1_000)
                return AXValueCreate(.cgSize, &size)
            default:
                return nil
            }
        }

        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            nil
        }
    }

    private let point = CGPoint(x: 5, y: 5)

    /// Children past the child limit are not weighed at all: one request, the start kept.
    @Test func aHugeFanOutIsNotWeighed() throws {
        let tree = Hostile(.fanOut)
        let end = try PointerWordReader.descend(from: tree.root, to: point, with: tree)
        #expect(!tree.overBudget)
        #expect(tree.requests == 1, "\(tree.requests) requests")
        #expect(end == tree.root)
    }

    /// An element that is its own child ends at the depth limit: three requests a level.
    @Test func aSelfCycleEndsAtTheDepthLimit() throws {
        let tree = Hostile(.selfCycle)
        _ = try PointerWordReader.descend(from: tree.root, to: point, with: tree)
        #expect(!tree.overBudget)
        #expect(tree.requests <= 3 * PointerWordReader.descentDepthLimit, "\(tree.requests) requests")
    }

    /// An endless chain stops at the depth limit, that many levels down.
    @Test func anEndlessChainStopsAtTheDepthLimit() throws {
        let tree = Hostile(.chain)
        let end = try PointerWordReader.descend(from: tree.root, to: point, with: tree)
        var pid: pid_t = 0
        AXUIElementGetPid(end, &pid)
        #expect(!tree.overBudget)
        #expect(pid == Hostile.rootPid + Int32(PointerWordReader.descentDepthLimit))
        #expect(tree.requests <= 3 * PointerWordReader.descentDepthLimit, "\(tree.requests) requests")
    }
}

import ApplicationServices
import XDictCapture

/// Everything a hover asks of the screen through Accessibility — **the seam the hover reader's tests replace**
/// (ported from XiaolaiDict's `ScreenWordSource`, its recogniser left for plan-capture WI-4).
public protocol PointerWordSource: Sendable {
    /// The compositor's on-screen windows, front to back, every level.
    func listedWindows() -> [ListedWindow]
    /// Who owns the pixel, through Accessibility, without reading any text.
    func target(at point: CGPoint, windows: @escaping @Sendable () -> [ListedWindow]) async -> PointerWordReader.TargetOutcome
    /// **The site check and the text read as one lane job** — the only way to read a hover's text, so no page can
    /// navigate between a check and a read. The text is read only where `refuses` does not refuse the site.
    func readUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: @escaping @Sendable (HostReading) -> Bool,
        budget: Duration
    ) async -> PointerWordReader.GatedOutcome
    /// What the one lane is doing now — for the "capture stuck" notice (ADR-0014 decision 6), which the consumer words.
    func laneState() -> LaneState
}

/// **The real screen, through the one lane as hover work** (XDict ADR-0014 decision 6): coalesced with the hovers
/// before it, behind every explicit read, under the hover messaging timeout, its session — and so its hit test — made
/// when its turn comes. The caller's cancellation is passed on, which a detached read would not inherit.
public struct SystemPointerWords: PointerWordSource {
    private let lane: AccessibilityLane
    private let access: AccessibilityAccess
    private let tolerance: HitTolerance
    private let limits: CaptureLimits
    private let client: @Sendable (Duration) -> any AccessibilityReading

    /// `tolerance` comes from the composition layer's tokens (decision 11), never a literal here.
    public init(
        tolerance: HitTolerance, limits: CaptureLimits = .shipped, lane: AccessibilityLane = .system,
        access: AccessibilityAccess = .system,
        client: @escaping @Sendable (Duration) -> any AccessibilityReading = { AccessibilitySession(budget: $0) }
    ) {
        self.client = client
        self.tolerance = tolerance
        self.limits = limits
        self.lane = lane
        self.access = access
    }

    /// Owner and frame are public; only a window's title needs Screen Recording, and nothing here asks for it.
    public func listedWindows() -> [ListedWindow] {
        PointerWindow.listed(
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? [])
    }

    public func target(
        at point: CGPoint, windows: @escaping @Sendable () -> [ListedWindow]
    ) async -> PointerWordReader.TargetOutcome {
        let access = access
        let client = client
        let budget = PointerWordReader.budget
        return await lane.run(.hover, timeout: PointerWordReader.messagingTimeout, budget: budget, {
            PointerWordReader.target(at: point, access: access, windows: windows, ownProcess: getpid(),
                                     with: client(budget))
        }, refused: { .none(.failed(Self.failure(for: $0))) })
    }

    public func readUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: @escaping @Sendable (HostReading) -> Bool,
        budget: Duration
    ) async -> PointerWordReader.GatedOutcome {
        let tolerance = tolerance
        let limits = limits
        let client = client
        return await lane.run(.hover, timeout: PointerWordReader.messagingTimeout, budget: budget, {
            PointerWordReader.readUnlessRefused(at: point, in: target, tolerance: tolerance, limits: limits,
                                                refuses: refuses, with: client(budget))
        }, refused: { refusal in
            switch refusal {
            case .cancelled, .superseded: .read(.cancelled)
            case .overstayed, .stuck: .read(.miss(.failed(Self.failure(for: refusal), app: target.appName)))
            }
        })
    }

    public func laneState() -> LaneState { lane.current() }

    /// The lane's refusal as the read's failure: a stuck lane is an app not answering; a hover that waited too long is
    /// one past its deadline.
    static func failure(for refusal: LaneRefusal) -> CaptureError {
        switch refusal {
        case .cancelled, .superseded: .cancelled
        case .overstayed: .deadlineExceeded
        case .stuck: .notResponding
        }
    }
}

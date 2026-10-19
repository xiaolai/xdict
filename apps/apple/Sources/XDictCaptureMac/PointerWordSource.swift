import ApplicationServices
import XDictCapture

/// Everything a hover asks of the screen — through Accessibility, and through the recogniser where Accessibility finds no
/// word — **the seam the hover reader's tests replace** (ported from XiaolaiDict's `ScreenWordSource`).
public protocol PointerWordSource: Sendable {
    /// The compositor's on-screen windows, front to back, every level.
    func listedWindows() -> [ListedWindow]
    /// Who owns the pixel, through Accessibility, without reading any text — through the lane. An app `refusesOwner`
    /// refuses is asked nothing where it is known before the hit test (`PointerWordReader.target`). A window of XDict's
    /// is answered `ownWindow`, unasked: its hit test is the main actor's (`ownTarget`).
    func target(
        at point: CGPoint, windows: @escaping @Sendable () -> [ListedWindow],
        refusesOwner: @escaping @Sendable (pid_t) -> Bool
    ) async -> PointerWordReader.TargetOutcome
    /// **The site check and the text read as one lane job** — the only way to read another app's hover text, so no page
    /// can navigate between a check and a read. The text is read only where `refuses` does not refuse the site.
    func readUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: @escaping @Sendable (HostReading) -> Bool,
        budget: Duration
    ) async -> PointerWordReader.GatedOutcome
    /// **XDict's own window: the hit test on the main actor**, through XDict's own application, never through the lane
    /// (owner, 2026-10-19; XiaolaiDict ADR-0042: a request about this process is serviced on the calling thread).
    @MainActor func ownTarget(at point: CGPoint) -> PointerWordReader.OwnTargetOutcome
    /// **XDict's own window: the same combined site check and read, on the main actor**, under the same budget and limits.
    @MainActor func readOwnUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: (HostReading) -> Bool, budget: Duration
    ) -> PointerWordReader.GatedOutcome
    /// What the one lane is doing now — for the "capture stuck" notice (ADR-0014 decision 6), which the consumer words.
    func laneState() -> LaneState
    /// **The pixels of `window` around `point`, read** (plan-capture WI-4): consent first and the window's owner against
    /// `policy` before any pixel, never prompting (decision 7). Throws a `RecognitionError`, or the caller's cancellation.
    func recognise(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Recognition
}

/// **The real screen, through the one lane as hover work** (XDict ADR-0014 decision 6) — every app but XDict, whose own
/// windows are asked on the main actor (`ownTarget`, `readOwnUnlessRefused`): coalesced with the hovers
/// before it, behind every explicit read, under the hover messaging timeout, its session — and so its hit test — made
/// when its turn comes. The caller's cancellation is passed on, which a detached read would not inherit.
public struct SystemPointerWords: PointerWordSource {
    private let lane: AccessibilityLane
    private let access: AccessibilityAccess
    private let tolerance: HitTolerance
    private let limits: CaptureLimits
    private let recogniser: ScreenTextRecogniser
    private let client: @Sendable (Duration) -> any AccessibilityReading
    private let windows: @Sendable () -> [ListedWindow]

    /// `metrics` come from the composition layer's tokens (decision 11), never a literal here; `screen` is the one owner
    /// of the Screen Recording grant the recogniser reads; `windows` is the compositor's list (a test's, in a test).
    public init(
        metrics: CaptureMetrics, limits: CaptureLimits = .shipped, lane: AccessibilityLane = .system,
        access: AccessibilityAccess = .system, screen: ScreenRecordingAccess = .system,
        windows: @escaping @Sendable () -> [ListedWindow] = SystemPointerWords.compositorWindows,
        client: @escaping @Sendable (Duration) -> any AccessibilityReading = { AccessibilitySession(budget: $0) }
    ) {
        self.client = client
        self.windows = windows
        self.tolerance = metrics.hit
        self.limits = limits
        self.lane = lane
        self.access = access
        recogniser = ScreenTextRecogniser(metrics: metrics, limits: limits, access: screen)
    }

    /// Owner and frame are public; only a window's title needs Screen Recording, and nothing here asks for it.
    public func listedWindows() -> [ListedWindow] { windows() }

    /// The compositor's on-screen windows, front to back, every level.
    public static func compositorWindows() -> [ListedWindow] {
        PointerWindow.listed(
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? [])
    }

    public func target(
        at point: CGPoint, windows: @escaping @Sendable () -> [ListedWindow],
        refusesOwner: @escaping @Sendable (pid_t) -> Bool
    ) async -> PointerWordReader.TargetOutcome {
        let access = access
        let client = client
        let budget = PointerWordReader.budget
        return await lane.run(.hover, timeout: PointerWordReader.messagingTimeout, budget: budget, {
            PointerWordReader.target(at: point, access: access, windows: windows, ownProcess: getpid(),
                                     refusesOwner: refusesOwner, with: client(budget))
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

    /// **On the main actor, never through the lane**: a lane job about this process would be serviced on the lane's
    /// thread (XiaolaiDict ADR-0042), and the main actor would wait on it. Its own session, the hover budget.
    @MainActor
    public func ownTarget(at point: CGPoint) -> PointerWordReader.OwnTargetOutcome {
        PointerWordReader.ownTarget(at: point, access: access, ownProcess: getpid(), with: client(PointerWordReader.budget))
    }

    /// The same combined job as `readUnlessRefused`, the same tolerance and limits, on the main actor under `budget`.
    @MainActor
    public func readOwnUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: (HostReading) -> Bool, budget: Duration
    ) -> PointerWordReader.GatedOutcome {
        PointerWordReader.readUnlessRefused(at: point, in: target, tolerance: tolerance, limits: limits, refuses: refuses,
                                            with: client(budget))
    }

    public func laneState() -> LaneState { lane.current() }

    /// **Not through the lane**: the recogniser reads pixels, not another process's Accessibility, so a wedged capture
    /// never holds a read the shortcut waits on — and a wedged lane never holds a capture (decision 8).
    public func recognise(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Recognition {
        try await recogniser.read(at: point, window: window, policy: policy)
    }

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

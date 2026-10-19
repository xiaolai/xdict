import AppKit
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
    /// **What is under the point in XDict's own window, by window and view geometry on the main actor**: a web view of
    /// XDict's, which is never asked through Accessibility (its own reading instead), or its native controls.
    @MainActor func ownView(at point: CGPoint) -> OwnView
    /// **XDict's own controls: the hit test, a lane job run on the main actor**, through XDict's own application (owner,
    /// 2026-10-19; XiaolaiDict ADR-0042: a request about this process is serviced on the calling thread), under the
    /// hover timeout the lane sets and the hover budget.
    func ownTarget(at point: CGPoint) async -> PointerWordReader.OwnTargetOutcome
    /// **XDict's own controls: the same combined site check and read, a lane job run on the main actor**, under the same
    /// timeout, budget and limits.
    func readOwnUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: @escaping @Sendable (HostReading) -> Bool,
        budget: Duration
    ) async -> PointerWordReader.GatedOutcome
    /// What the one lane is doing now — for the "capture stuck" notice (ADR-0014 decision 6), which the consumer words.
    func laneState() -> LaneState
    /// **The pixels of `window` around `point`, read** (plan-capture WI-4): consent first and the window's owner against
    /// `policy` before any pixel, never prompting (decision 7). Throws a `RecognitionError`, or the caller's cancellation.
    func recognise(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Recognition
}

/// **The real screen, through the one lane as hover work** (XDict ADR-0014 decision 6) — XDict's own controls included,
/// as lane jobs run on the main actor (`ownTarget`, `readOwnUnlessRefused`), and XDict's own web views never, read by
/// their own means (`ownView`): coalesced with the hovers
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
    private let readsOwnView: @MainActor @Sendable (NSView, CGPoint) -> OwnViewReading?

    /// `metrics` come from the composition layer's tokens (decision 11), never a literal here; `screen` is the one owner
    /// of the Screen Recording grant the recogniser reads; `windows` is the compositor's list (a test's, in a test).
    /// `readsOwnView` reads one of XDict's web views by its own means, given the view and the point in it (y down from
    /// its top) — the composition layer's, which knows the entry view; with none, a web view of XDict's is asked nothing.
    public init(
        metrics: CaptureMetrics, limits: CaptureLimits = .shipped, lane: AccessibilityLane = .system,
        access: AccessibilityAccess = .system, screen: ScreenRecordingAccess = .system,
        windows: @escaping @Sendable () -> [ListedWindow] = SystemPointerWords.compositorWindows,
        readsOwnView: @escaping @MainActor @Sendable (NSView, CGPoint) -> OwnViewReading? = { _, _ in nil },
        client: @escaping @Sendable (Duration) -> any AccessibilityReading = { AccessibilitySession(budget: $0) }
    ) {
        self.client = client
        self.windows = windows
        self.readsOwnView = readsOwnView
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

    /// The window AppKit would give a click at the point, and the view under it there (`OwnViews`); a web view is read
    /// by `readsOwnView`, or by nothing.
    @MainActor
    public func ownView(at point: CGPoint) -> OwnView {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return OwnViews.view(at: point, in: OwnViews.window(at: point, primaryHeight: primaryHeight),
                             primaryHeight: primaryHeight, reading: readsOwnView)
    }

    /// **A lane job run on the main actor** (`AccessibilityLane.submitOnMainActor`): the request is serviced on the main
    /// thread, as one about this process must be, under the hover timeout the lane sets for it. Its own session, the hover
    /// budget.
    public func ownTarget(at point: CGPoint) async -> PointerWordReader.OwnTargetOutcome {
        let access = access
        let client = client
        let budget = PointerWordReader.budget
        return await lane.runOnMainActor(.hover, timeout: PointerWordReader.messagingTimeout, budget: budget, {
            PointerWordReader.ownTarget(at: point, access: access, ownProcess: getpid(), with: client(budget))
        }, refused: { .none(.failed(Self.failure(for: $0))) })
    }

    /// The same combined job as `readUnlessRefused`, the same timeout, tolerance and limits, a lane job run on the main
    /// actor under `budget`.
    public func readOwnUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: @escaping @Sendable (HostReading) -> Bool,
        budget: Duration
    ) async -> PointerWordReader.GatedOutcome {
        let tolerance = tolerance
        let limits = limits
        let client = client
        return await lane.runOnMainActor(.hover, timeout: PointerWordReader.messagingTimeout, budget: budget, {
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

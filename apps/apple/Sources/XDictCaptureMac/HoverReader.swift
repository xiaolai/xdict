import AppKit
import XDictBase
import XDictCapture
import os

/// What `HoverWatcher` needs of a reader — the seam its event-sequence tests replace.
@MainActor
protocol HoverReading: AnyObject {
    /// Called when the one lane, or the one capture, stops answering, and again when it answers.
    var onCaptureHealth: (@MainActor (CaptureHealth) -> Void)? { get set }
    /// Called when the one capture that may be in flight ends, so a hover refused `.captureInFlight` is asked again rather
    /// than waiting for the pointer to twitch.
    var onCaptureReleased: (@MainActor () -> Void)? { get set }
    /// `begin` numbers the request, called once the gate has said yes and before anything is read.
    func read(
        at point: CGPoint, modifiersHeld: Set<HoverModifier>, tappedTwice: Bool, pointerStillFor: Duration,
        begin: @MainActor () -> CaptureRequest
    ) async -> HoverReader.Outcome
    /// The word under `key` was delivered: resting on it again is not a new request.
    func remember(_ key: String)
    /// The word under `key` never reached the reader — its presentation did not draw — so resting on it again **is** a
    /// new request. Forgets only that word: a later one remembered since stands.
    func forget(_ key: String)
    /// The hold key came up: the hover is over, and the next one may look the same word up again.
    func endHover()
}

/// Whether hover's reads are answering: **the lane's** (ADR-0014 decision 6: a read blocked inside another process's
/// Accessibility call cannot be cancelled) **or the capture's** (decision 8: a screen capture held past its deadline is
/// not let go of). Either is reported once, and the recovery once, when neither is stuck. The consumer words it.
public enum CaptureHealth: Sendable, Equatable {
    case answering
    /// Blocked for this long when it was noticed.
    case stuck(for: Duration)
}

/// **One hover: the gate, then who owns the pixel, then the text in one lane job, and the pixels where it found no word**
/// (ported from XiaolaiDict's `HoverReader`, plan-capture WI-3 and WI-4).
///
/// - `HoverPolicy` decides whether to look at all, **first**, so a reader who is simply reading never pays for anything.
/// - **Accessibility first**: the text is read only through `PointerWordSource.readUnlessRefused` (WI-2), the site check
///   and the read one job — or, for XDict's own controls, the same job run on the main actor (`readOwnUnlessRefused`).
///   **XDict's own web views are never asked through Accessibility**: their own reading answers (`readOwnView`), and an
///   entry is XDict's page, not a site, so no site rule applies to it. **The recogniser only where that found no word** — and never where it refused the site, nor,
///   with no element to name a page, while the reader excludes any site (the same `HoverPolicy.refuses` rule: an unnamed
///   page is unreadable). The window's owner is checked before a pixel and the word's after.
/// - **One capture at a time** (`CaptureGuard`), bounded by `captureDeadline`, and the guard released by the capture's own
///   end: a wedge is reported at the deadline and its recovery when the capture returns, while Accessibility goes on
///   answering. **The rest of a sentence** is read under the same guard as a `PendingContext`, started in `contexts` and
///   bounded by what is left of the deadline.
@MainActor
public final class HoverReader: HoverReading {
    private let log = Logger(subsystem: XDictIdentity.app, category: "hover")
    private let source: any PointerWordSource
    private let policy: @MainActor () -> HoverPolicy
    private let pause: @MainActor () -> HoverPause
    /// The whole Accessibility read's budget.
    private let budget: Duration
    /// The book a reading's pending context is started in: the consumer's session finds it there by handle.
    let contexts: PendingContexts
    /// How long a capture may answer in before it is reported stuck — the shipped one protects the reader.
    private let captureDeadline: Duration
    private let capturing: CaptureGuard
    private let passesClicksThrough: @MainActor (UInt32) -> Bool
    /// XDict's own bundle identifier, which the reader may exclude like any app's.
    private let ownBundleID: String?
    /// What one of XDict's own web views may answer, at most (`contextUTF16`).
    private let limits: CaptureLimits
    /// The bundle identifier of a window's owner, by its pid; nil where it cannot be named.
    private let bundleIDOf: @MainActor (pid_t) -> String?
    var onCaptureHealth: (@MainActor (CaptureHealth) -> Void)?
    var onCaptureReleased: (@MainActor () -> Void)?
    /// The lane's wedge, and the capture's, as last reported.
    private var laneStuck = false
    private var captureStuck = false
    /// How long past the deadline an unwatched capture is looked at again: enough that "held past the deadline" is true.
    static let stuckCheckMargin: Duration = .milliseconds(100)

    /// The word the last hover looked up, so resting on it does not look it up again. **Written when a word is
    /// delivered**, by `remember`; **cleared when the hover ends** (the key up, no tap) and when its presentation never
    /// drew (`forget`). A key, not a record: it is compared only with the next read's, in memory.
    var lastLookedUp: String?

    public init(
        policy: @escaping @MainActor () -> HoverPolicy, pause: @escaping @MainActor () -> HoverPause = { HoverPause() },
        source: any PointerWordSource, budget: Duration = PointerWordReader.budget, contexts: PendingContexts,
        captureDeadline: Duration = ScreenTextRecogniser.captureDeadline, capturing: CaptureGuard = CaptureGuard(),
        passesClicksThrough: @escaping @MainActor (UInt32) -> Bool = {
            HoverReader.passesClicksThrough($0, among: NSApp?.windows ?? [])
        },
        ownBundleID: String? = Bundle.main.bundleIdentifier, limits: CaptureLimits = .shipped,
        bundleIDOf: @escaping @MainActor (pid_t) -> String? = {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }
    ) {
        self.bundleIDOf = bundleIDOf
        self.limits = limits
        self.passesClicksThrough = passesClicksThrough
        self.ownBundleID = ownBundleID
        self.policy = policy
        self.pause = pause
        self.source = source
        self.budget = budget
        self.contexts = contexts
        self.captureDeadline = captureDeadline
        self.capturing = capturing
    }

    /// Why a hover the gate allowed found no word: typed, and metadata only.
    public enum Nothing: Sendable, Equatable {
        /// Accessibility named no element at the point (or is not granted), and there were no pixels to read either.
        case noTarget(PointerWordReader.TargetMiss)
        /// The element named had no word there, or a request failed.
        case miss(PointerWordReader.Miss)
        /// The recogniser read nothing, with why.
        case recognition(RecognitionError)
        /// The capture did not answer within its deadline; it still holds the one capture.
        case captureTimedOut
    }

    public enum Outcome: Sendable {
        /// A word Accessibility read, the request it was read for, and the key that suppresses it once delivered.
        case word(PointerWordReader.Hit, request: CaptureRequest, key: String)
        /// A word the recogniser read, its request and key, and the rest of its sentence still being read — nil where there
        /// is none. **Whoever drops the word cancels the context**: it holds the one capture until it ends.
        case recognised(Recognition, request: CaptureRequest, key: String, context: PendingContext?)
        /// The gate, or a refusal after the read. Ordinary, and not worth showing.
        case quiet(HoverRefusal)
        /// The gate said yes and nothing could be read: not in XDict's own window (its script, controls and pixels), not
        /// in the first app behind it, and nowhere else the point reaches.
        case nothing(Nothing)
        /// Only the pixels could answer, and Screen Recording is not set up or is off. **Nothing was asked of the system**:
        /// the consumer tells the reader where to allow it.
        case needsScreenRecording(request: CaptureRequest)
    }

    public func read(
        at point: CGPoint, modifiersHeld: Set<HoverModifier>, tappedTwice: Bool, pointerStillFor: Duration,
        begin: @MainActor () -> CaptureRequest
    ) async -> Outcome {
        let policy = policy()
        // **A completed double-tap is a new request, and says so**: the same word tapped twice in a row is asked again.
        if tappedTwice { lastLookedUp = nil }
        // **The cheap refusals first, before any IPC.** A busy capture is not refused here: only the pixel path needs
        // the one guard, and Accessibility goes on answering while a capture is wedged (decision 8).
        let ungated = policy.decide(
            at: HoverSite(bundleID: nil), modifiersHeld: modifiersHeld, tappedTwice: tappedTwice,
            pointerStillFor: pointerStillFor, pausedUntil: pause().until, lastLookedUp: nil, captureInFlight: false,
            now: .now)
        if case .stayQuiet(let refusal) = ungated {
            // **Both gestures' "the reader is not asking" ends the hover**, and with it the suppression.
            if refusal == .modifierNotHeld || refusal == .notTapped { lastLookedUp = nil }
            return .quiet(refusal)
        }
        // **The request's place in line is now**, when the gate accepted the gesture.
        let request = begin()

        // **Who owns the pixel, from the compositor first**, before Accessibility is asked anything — without XDict's own
        // click-through windows (the hover notice, the popover's anchor), which carry no reader text. The same list
        // serves the pixel path.
        let ours = getpid()
        let windows = PointerWindow.withoutClickThrough(source.listedWindows(), ours: ours,
                                                        passesClicksThrough: passesClicksThrough)
        if policy.readingMode == .screenOnly {
            return await readScreenOnly(at: point, windows: windows, request: request, policy: policy)
        }
        switch await resolve(at: point, windows: windows, policy: policy) {
        case nil: return .quiet(.excludedApp)
        case .ownView(let reading)?:
            // **XDict's own window is read completely before anything behind it**: the view's own answer, then its
            // visible pixels, then the first app behind.
            let outcome = await readOwnView(reading, at: point, request: request, policy: policy)
            return await lookThrough(after: outcome, at: point, windows: windows, request: request, policy: policy)
        case .target(let found, let own)?:
            let outcome: Outcome
            switch found {
            case .none(let why):
                // **No element, so no page to name**: for another app, read as pixels only while the reader excludes no
                // site — the rule the text read applies to an unreadable page. XDict's own window holds no site.
                if !own, let refusal = CaptureAuthorization.refusal(host: .unreadable, policy: policy) {
                    return .quiet(refusal)
                }
                // XDict's own window's pixels are `lookThrough`'s first step, once — never read twice.
                outcome = own ? .nothing(.noTarget(why))
                              : await pixels(at: point, owner: nil, windows: windows, otherwise: .noTarget(why),
                                             request: request, policy: policy)
            case .found(let target):
                outcome = await readTarget(target, ownerIsOurs: own, at: point, windows: windows, request: request,
                                           policy: policy)
            }
            guard own else { return outcome }
            return await lookThrough(after: outcome, at: point, windows: windows, request: request, policy: policy)
        }
    }

    /// What one app's element read decided, before any pixels: an answer to return, or a miss whose window is read as
    /// pixels next.
    private enum GatedRead {
        case answer(Outcome)
        case miss(Nothing)
    }

    /// **The one place a named app's element is read** — the front path and the look-through alike: the app's refusal, the
    /// gated read (on the main actor where the element is XDict's), the word, and a secure field's answer. The lane's
    /// health is noted after the read, as it is after the hit test (`resolve`), so a wedge during either is reported.
    private func gatedRead(
        _ target: PointerWordReader.Target, ownerIsOurs own: Bool, at point: CGPoint, request: CaptureRequest,
        policy: HoverPolicy
    ) async -> GatedRead {
        if let refusal = CaptureAuthorization.refusal(bundleID: target.bundleID, policy: policy) {
            return .answer(.quiet(refusal))
        }
        guard !Task.isCancelled else { return .answer(.quiet(.cancelled)) }
        // **An element of this process is read on the main actor, by its pid** (`AXUIElementGetPid`), whichever hit test
        // found it: a lane job run there, never on the lane's own thread, where it would be serviced off it.
        let gated: PointerWordReader.GatedOutcome
        if own || target.pid == getpid() {
            gated = await source.readOwnUnlessRefused(at: point, in: target, refuses: { policy.refuses($0) },
                                                      budget: budget)
        } else {
            gated = await source.readUnlessRefused(at: point, in: target, refuses: { policy.refuses($0) },
                                                   budget: budget)
        }
        noteLane()
        switch gated {
        case .refused:
            return .answer(.quiet(.excludedSite))
        case .read(.hit(let hit)):
            return .answer(accept(hit, request: request, policy: policy, point: point))
        case .read(.cancelled):
            return .answer(.quiet(.cancelled))
        case .read(.miss(.secure(let app))):
            return .answer(.nothing(.miss(.secure(app: app))))
        case .read(.miss(let miss)):
            log.info("hover: accessibility found no word (\(String(describing: miss), privacy: .public))")
            return .miss(.miss(miss))
        }
    }

    /// The front path once `resolve` named an element: the gated read, then **that window's pixels** where it found no
    /// word — except XDict's own window, whose pixels `lookThrough` reads once. A secure field is read neither as pixels
    /// nor through: it is the window's answer at this point.
    private func readTarget(
        _ found: PointerWordReader.Target, ownerIsOurs own: Bool, at point: CGPoint, windows: [ListedWindow],
        request: CaptureRequest, policy: HoverPolicy
    ) async -> Outcome {
        switch await gatedRead(found, ownerIsOurs: own, at: point, request: request, policy: policy) {
        case .answer(let outcome):
            return outcome
        case .miss(let why):
            guard !own else { return .nothing(why) }
            return await pixels(at: point, owner: found.pid, windows: windows, otherwise: why,
                                request: request, policy: policy)
        }
    }

    /// **XDict's window is transparent to hover where it holds no word** (owner, 2026-10-24: "哪怕它与其他窗口重叠或者当前
    /// frontmost 的时候也不能鼠标取词，这就不对了"). The surface the reader sees is read completely first — its pixels, so
    /// text in an image is found — and then the first ordinary window of another app behind it, through that app's own
    /// Accessibility and then its pixels. **A word the screen shows is never answered "no word"**; only when every window
    /// at the point has been read is the miss reported, and a pixel read that needed Screen Recording says so. Each read
    /// keeps the program it was made in: a capture names its window's owner.
    private func lookThrough(
        after outcome: Outcome, at point: CGPoint, windows: [ListedWindow], request: CaptureRequest, policy: HoverPolicy
    ) async -> Outcome {
        let ownWhy: Nothing
        switch outcome {
        case .nothing(.miss(.secure)): return outcome  // a secure field is nobody's to read: not pierced
        case .nothing(let why): ownWhy = why
        default: return outcome
        }
        var permission: Outcome?
        var reasons: [Nothing] = [ownWhy]
        // Every ending passes here: a timeout recorded by any window is never lost to a later quiet or blander outcome.
        func ended(_ outcome: Outcome) -> Outcome {
            settle(outcome, timedOut: reasons.contains(.captureTimedOut), permission: permission)
        }
        if let own = frontOwnWindow(at: point, in: windows) {
            switch await readThePixels(of: own, at: point, request: request, policy: policy) {
            case .nothing(let why): reasons.append(why)
            case .needsScreenRecording: permission = .needsScreenRecording(request: request)
            case let found: return ended(found)
            }
        }
        guard let behind = behindWindow(at: point, in: windows) else {
            return ended(.nothing(Self.telling(reasons, fallback: ownWhy)))
        }
        if let refusal = CaptureAuthorization.refusal(bundleID: bundleIDOf(behind.pid), policy: policy) {
            return ended(.quiet(refusal))
        }
        let behindWhy: Nothing
        switch await source.target(of: behind.pid, at: point) {
        case .found(let target):
            noteLane()
            if let refusal = CaptureAuthorization.refusal(bundleID: target.bundleID, policy: policy) {
                return ended(.quiet(refusal))
            }
            switch await gatedRead(target, ownerIsOurs: false, at: point, request: request, policy: policy) {
            case .answer(let answer):
                return ended(answer)
            case .miss(let why):
                behindWhy = why
            }
        case .none(let why):
            noteLane()
            // No element, so no page to name: where the reader excludes a site, the app behind is not read as pixels
            // either — the same rule the front path applies to an unreadable page.
            if let refusal = CaptureAuthorization.refusal(host: .unreadable, policy: policy) {
                return ended(.quiet(refusal))
            }
            behindWhy = .noTarget(why)
        case .ownWindow:
            noteLane()
            behindWhy = .noTarget(.nothingAtPointer)
        }
        switch await readThePixels(of: behind, at: point, request: request, policy: policy) {
        case .nothing(let why):
            return ended(.nothing(Self.telling(reasons + [behindWhy, why], fallback: behindWhy)))
        case .needsScreenRecording:
            return ended(.needsScreenRecording(request: request))
        case let found:
            return ended(found)
        }
    }

    /// **The most telling of the reasons the windows gave**: a capture past its deadline outranks a pixel read that failed
    /// for a reason (the window closed, its owner cannot be named), which outranks a wordless element, which outranks a
    /// pixel read that simply found no word, which outranks no element at all. The consumer words `.captureTimedOut` as
    /// the stuck capture, so no later, blander miss may hide it; and a view's own wordless answer is not buried under
    /// "nothing under pointer" from the pixels that followed it.
    private static func telling(_ reasons: [Nothing], fallback: Nothing) -> Nothing {
        func rank(_ reason: Nothing) -> Int {
            switch reason {
            case .captureTimedOut: return 5
            case .recognition(.nothingUnderPointer): return 2
            case .recognition: return 4
            case .miss: return 3
            case .noTarget: return 1
            }
        }
        return (reasons + [fallback]).max { rank($0) < rank($1) } ?? fallback
    }

    /// **The one ending of a look-through**: a word, a cancellation or the grant notice stands as it is; otherwise a
    /// capture past its deadline anywhere is the stuck capture the reader can act on — not a later, blander miss or a
    /// silent refusal — and a grant the read needed stands over a silent refusal (the reader's own list refuses the
    /// behind app, but the pixels of XDict's window were left unread for want of the grant).
    private func settle(_ outcome: Outcome, timedOut: Bool, permission: Outcome?) -> Outcome {
        switch outcome {
        case .word, .recognised, .needsScreenRecording, .quiet(.cancelled):
            return outcome
        default:
            break
        }
        if let permission { return permission }
        if timedOut { return .nothing(.captureTimedOut) }
        return outcome
    }

    /// **The first ordinary window of another app at the point** — the app the reader would see were XDict's window not
    /// there. A window at a layer above the ordinary ones is not that app's content at the point: Notification Center
    /// lists a full-screen layer-21 window on macOS 27.0.1 whose own hit test answers with its menu bar at any point
    /// (measured 2026-10-24), so only layer 0 names the app behind.
    private func behindWindow(at point: CGPoint, in windows: [ListedWindow]) -> ListedWindow? {
        windows.first { $0.pid != getpid() && $0.alpha > 0 && $0.layer == 0 && $0.bounds.contains(point) }
    }

    /// **The frontmost visible window of XDict's at the point** — the surface its own pixels are read from.
    private func frontOwnWindow(at point: CGPoint, in windows: [ListedWindow]) -> ListedWindow? {
        windows.first { $0.pid == getpid() && $0.alpha > 0 && $0.bounds.contains(point) }
    }

    /// **Read text with: Screen Only** (owner, 2026-10-19): Accessibility is never asked — no hit test, no site walk, no
    /// text, none of XDict's own views — and the pixels are read under the rules they already keep. **XDict's front window
    /// is read first, then the first app behind it** (owner, 2026-10-24: a word on screen is never answered "no word"):
    /// both as pixels, since this mode has no other means. With no element, no page can be named, so while the reader
    /// excludes any site a window that may hold one is refused, as the pixel path refuses an unnamed page; XDict excluded
    /// by the reader refuses its own front window here, another app's exclusion is the recogniser's, by the window's
    /// owner, before a pixel; and without Screen Recording the reader is told so (`needsScreenRecording`).
    private func readScreenOnly(
        at point: CGPoint, windows: [ListedWindow], request: CaptureRequest, policy: HoverPolicy
    ) async -> Outcome {
        guard !Task.isCancelled else { return .quiet(.cancelled) }
        let ours = getpid()
        let inOwnWindow = PointerWindow.ownership(at: point, in: windows, ours: ours) == .ours
        if inOwnWindow, let refusal = CaptureAuthorization.refusal(bundleID: ownBundleID, policy: policy) {
            return .quiet(refusal)
        }
        guard inOwnWindow else {
            // **No page can be named without Accessibility**: while a site is listed, the window the capture would read is
            // refused where it may hold one — a known browser's, or one whose owner cannot be named (`refusesUnnamedPage`).
            if policy.refuses(.unreadable),
               case .window(let chosen, _) = PointerTarget(point: point, windows: windows, accessibilityOwner: nil)
                   .captureWindow(excludingProcess: ours),
               policy.refusesUnnamedPage(in: bundleIDOf(chosen.pid)) {
                return .quiet(.excludedSite)
            }
            return await pixels(at: point, owner: nil, windows: windows, otherwise: .noTarget(.nothingAtPointer),
                                request: request, policy: policy)
        }
        var permission: Outcome?
        var reasons: [Nothing] = []
        func ended(_ outcome: Outcome) -> Outcome {
            settle(outcome, timedOut: reasons.contains(.captureTimedOut), permission: permission)
        }
        // **The surface the reader sees, then the app behind it**: XDict's window holds XDict's pages, never a site, so
        // the site rule is asked of the window behind only.
        if let own = frontOwnWindow(at: point, in: windows) {
            switch await readThePixels(of: own, at: point, request: request, policy: policy) {
            case .nothing(let why): reasons.append(why)
            case .needsScreenRecording: permission = .needsScreenRecording(request: request)
            case let found: return ended(found)
            }
        }
        guard let behind = behindWindow(at: point, in: windows) else {
            return ended(.nothing(Self.telling(reasons, fallback: .noTarget(.nothingAtPointer))))
        }
        if policy.refuses(.unreadable), policy.refusesUnnamedPage(in: bundleIDOf(behind.pid)) {
            return ended(.quiet(.excludedSite))
        }
        switch await readThePixels(of: behind, at: point, request: request, policy: policy) {
        case .nothing(let why):
            return ended(.nothing(Self.telling(reasons + [why], fallback: .noTarget(.nothingAtPointer))))
        case .needsScreenRecording: return ended(.needsScreenRecording(request: request))
        case let found: return ended(found)
        }
    }

    /// Who owns the point, as `resolve` found it: an Accessibility target (true where it is XDict's own window), or one
    /// of XDict's own web views, which Accessibility is never asked about.
    private enum Resolved {
        case target(PointerWordReader.OwnTargetOutcome, own: Bool)
        case ownView(OwnViewReading?)
    }

    /// **Where the hit test is made** (owner, 2026-10-19: hover reads XDict's own windows): a window of XDict's in front
    /// at the point is looked at first by view geometry on the main actor (`ownView`) — a web view of XDict's is read by
    /// its own means, never through Accessibility — and its controls are asked through XDict's own application, a lane
    /// job run on the main actor (`ownTarget`); every other window through the lane, an excluded app known before its hit
    /// test asked nothing; and a window of XDict's the lane's hit test found after the list was taken is looked at again
    /// here the same way, rather than read off it.
    ///
    /// **Nil where the reader excluded XDict itself** (Never look up in ▸ Add an App…; the shipped list never holds it):
    /// refused by the same bundle-identifier rule as any app, before any view or element of XDict's is looked at.
    private func resolve(at point: CGPoint, windows: [ListedWindow], policy: HoverPolicy) async -> Resolved? {
        if PointerWindow.ownership(at: point, in: windows, ours: getpid()) == .ours {
            log.debug("hover: one of XDict's own windows; read on the main actor")
            return await ownWindowTarget(at: point, policy: policy)
        }
        let refusesOwner: @Sendable (pid_t) -> Bool = { pid in
            CaptureAuthorization.refusal(bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                                         policy: policy) != nil
        }
        let targeted = await source.target(at: point, windows: { windows }, refusesOwner: refusesOwner)
        noteLane()
        switch targeted {
        case .found(let target): return .target(.found(target), own: false)
        case .none(let why): return .target(.none(why), own: false)
        case .ownWindow:
            guard !Task.isCancelled else { return .target(.none(.failed(.cancelled)), own: true) }
            log.debug("hover: one of XDict's own windows, found by the lane; read on the main actor")
            return await ownWindowTarget(at: point, policy: policy)
        }
    }

    /// XDict's own window — unless the reader excluded XDict, which is refused first: the view under the point, and only
    /// where that is no web view, the hit test of XDict's own application.
    private func ownWindowTarget(at point: CGPoint, policy: HoverPolicy) async -> Resolved? {
        guard CaptureAuthorization.refusal(bundleID: ownBundleID, policy: policy) == nil else { return nil }
        switch source.ownView(at: point) {
        case .webView(let reading):
            log.debug("hover: one of XDict's own web views; asked by its own means")
            return .ownView(reading)
        case .controls:
            let targeted = await source.ownTarget(at: point)
            noteLane()
            return .target(targeted, own: true)
        }
    }

    /// What came first: the view's answer, the budget, or the caller giving up.
    private enum ViewRead: Sendable {
        case read(OwnViewText?)
        case timedOut
        case cancelled
    }

    /// **One of XDict's own web views, read by its own means**, under the hover budget and asked for at most
    /// `limits.contextUTF16` units; its answer was checked before it arrived (`OwnViewText`). A view nothing reads, or one
    /// that does not answer within the budget, is a miss — and a miss over XDict's own window is not the end: the window's
    /// pixels and then the app behind it are read (`lookThrough`), so a word on screen is never answered "no word".
    /// Accessibility over the view is never asked: it would wait on WebKit.
    private func readOwnView(
        _ reading: OwnViewReading?, at point: CGPoint, request: CaptureRequest, policy: HoverPolicy
    ) async -> Outcome {
        let app = NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
        guard let reading else { return .nothing(.miss(.noText(app: app, role: nil))) }
        let answer = Answer<ViewRead>()
        let most = limits.contextUTF16
        let asking = Task { @MainActor in answer.give(.read(await reading(most))) }
        let timer = Task {
            try? await Task.sleep(for: budget)
            answer.give(.timedOut)
        }
        let first = await withTaskCancellationHandler {
            await answer.value()
        } onCancel: {
            answer.give(.cancelled)
        }
        timer.cancel()
        asking.cancel()
        switch first {
        case .cancelled:
            return .quiet(.cancelled)
        case .timedOut:
            return .nothing(.miss(.failed(.deadlineExceeded, app: app)))
        case .read(let text):
            guard let word = text?.word else { return .nothing(.miss(.noText(app: app, role: nil))) }
            let hit = PointerWordReader.Hit(word: word, acquisition: .ownView, appName: app, bundleID: ownBundleID,
                                            bounds: nil)
            return accept(hit, request: request, policy: policy, point: point)
        }
    }

    /// **The capture path, once Accessibility had no word.** The window read is the one the app Accessibility named, where
    /// it named one; else the frontmost ordinary window not this process's. Every read is of one named window, so the
    /// word keeps its owner — the program it belongs to.
    private func pixels(
        at point: CGPoint, owner: pid_t?, windows: [ListedWindow], otherwise: Nothing, request: CaptureRequest,
        policy: HoverPolicy
    ) async -> Outcome {
        guard !Task.isCancelled else { return .quiet(.cancelled) }
        let window: ListedWindow
        switch PointerTarget(point: point, windows: windows, accessibilityOwner: owner).captureWindow(excludingProcess: getpid()) {
        case .window(let chosen, _):
            window = chosen
        case .ownerHasNoWindow, .noWindow:
            // No window a capture may read: what Accessibility found is the answer.
            return .nothing(otherwise)
        }
        return await readThePixels(of: window, at: point, request: request, policy: policy)
    }

    /// **One window's pixels, read**: one capture at a time, bounded, and its word attributed to the window's owner. A
    /// miss carries its own reason — the recognition's failure, or a capture past its deadline, which the consumer words
    /// as the stuck capture; a capture that could not run for lack of Screen Recording says so rather than "no word".
    private func readThePixels(
        of window: ListedWindow, at point: CGPoint, request: CaptureRequest, policy: HoverPolicy
    ) async -> Outcome {
        guard !Task.isCancelled else { return .quiet(.cancelled) }
        let abandoning = capturing.holdsAbandoned
        guard let ticket = capturing.claim() else {
            reportIfStuck()
            return .quiet(.captureInFlight)
        }
        if !abandoning, capturing.holdsAbandoned {
            log.notice("hover: a capture held past \(CaptureGuard.abandonAfter.components.seconds, privacy: .public) s was set aside; this one starts")
        }
        let source = source
        do {
            let (recognition, context) = try await bounded(ticket) {
                try await source.recognise(at: point, window: window, policy: policy)
            }
            let outcome = accept(recognition, context: context, request: request, policy: policy, point: point)
            if case .recognised = outcome {} else { context?.cancel() }
            return outcome
        } catch RecognitionError.screenBusy {
            // **A screenshot set aside is still blocked in ScreenCaptureKit**: this one was refused, never started beside
            // it (`ScreenshotGate`); asked again when the capture set aside ends.
            return .quiet(.captureInFlight)
        } catch RecognitionError.screenRecordingNeeded {
            // A reader who moved on is not told anything.
            return Task.isCancelled ? .quiet(.cancelled) : .needsScreenRecording(request: request)
        } catch let error as RecognitionError {
            return Task.isCancelled ? .quiet(.cancelled) : .nothing(.recognition(error))
        } catch is CaptureTimedOut {
            // **The deadline passed and the capture still runs**: stuck now, not when the next hover happens to ask.
            if capturing.isCurrent(ticket) { reportStuck(for: captureDeadline) }
            return .nothing(.captureTimedOut)
        } catch {
            return .quiet(.cancelled)
        }
    }

    /// The deadline won.
    private struct CaptureTimedOut: Error {}

    /// What came first: the first reading, a failure, the deadline, or the caller giving up.
    private enum FirstRead: Sendable {
        case read(Recognition, PendingContext?)
        case failed(any Error)
        case timedOut
        case cancelled
    }

    /// Runs `work` under the capture deadline and **releases the guard only when `work` itself ends** — which may be long
    /// after the deadline answered. Where the first reading offers a growth, it runs on under the same guard as a pending
    /// context, bounded by what is left of the deadline; the guard is released when that work returns.
    private func bounded(
        _ ticket: CaptureGuard.Ticket, _ work: @escaping @Sendable () async throws -> Recognition
    ) async throws -> (Recognition, PendingContext?) {
        let answer = Answer<FirstRead>()
        let capturing = capturing, contexts = contexts, deadline = captureDeadline
        let started = ContinuousClock.now
        let finished = Task { [weak self] in
            defer {
                let (_, wasReported) = capturing.release(ticket)
                Task { @MainActor in self?.captureEnded(wasReported: wasReported) }
            }
            let first: Recognition
            do { first = try await work() } catch {
                answer.give(.failed(error))
                return
            }
            guard let growth = first.growth, !Task.isCancelled else {
                answer.give(.read(first, nil))
                return
            }
            let left = max(.zero, deadline - (ContinuousClock.now - started))
            let context = contexts.start(fallback: first.context, bound: left, work: { await growth()?.context })
            // A reading the deadline already gave up on is shown to nobody: its context ends at once.
            if !answer.give(.read(first, context)) { context.cancel() }
            await context.finished()
        }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            answer.give(.timedOut)
        }
        let first = await withTaskCancellationHandler {
            await answer.value()
        } onCancel: {
            answer.give(.cancelled)
        }
        timer.cancel()
        // **A wedge is noticed even if nobody waits for it**: checked once the deadline has passed.
        scheduleStuckCheck()
        switch first {
        case .read(let recognition, let context):
            return (recognition, context)
        case .failed(let error):
            throw error
        case .timedOut:
            finished.cancel()
            throw CaptureTimedOut()
        case .cancelled:
            finished.cancel()
            throw CancellationError()
        }
    }

    /// The capture ended: a reported wedge recovers, and whatever waited for the guard is asked again.
    private func captureEnded(wasReported: Bool) {
        if wasReported {
            log.notice("hover: the screen capture answered again")
            setHealth(lane: laneStuck, capture: false, blocked: nil)
        }
        onCaptureReleased?()
    }

    private func scheduleStuckCheck() {
        guard let held = capturing.heldFor() else { return }
        let wait = max(.zero, captureDeadline - held) + Self.stuckCheckMargin
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            self?.reportIfStuck()
        }
    }

    private func reportIfStuck() {
        guard let held = capturing.overdue(after: captureDeadline) else { return }
        reportStuck(for: held)
    }

    /// Once per wedge: a fault in the log, and the consumer told.
    private func reportStuck(for held: Duration) {
        guard capturing.markReported() else { return }
        log.fault("hover: the screen capture has not answered for \(held.components.seconds, privacy: .public) s; no other may start until it does")
        setHealth(lane: laneStuck, capture: true, blocked: held)
    }

    /// **The one place health is told**: stuck when the first of the two wedges arrives, answering when neither is left.
    private func setHealth(lane: Bool, capture: Bool, blocked: Duration?) {
        let wasStuck = laneStuck || captureStuck
        laneStuck = lane
        captureStuck = capture
        let isStuck = lane || capture
        if isStuck, !wasStuck, let blocked { onCaptureHealth?(.stuck(for: blocked)) }
        if !isStuck, wasStuck { onCaptureHealth?(.answering) }
    }

    /// **The one place a read becomes an answer**: cancellation, then the refusals that need the word itself.
    private func accept(_ hit: PointerWordReader.Hit, request: CaptureRequest, policy: HoverPolicy, point: CGPoint) -> Outcome {
        if let refusal = refusal(bundleID: hit.bundleID, word: hit.word.word, policy: policy) { return .quiet(refusal) }
        let key = Self.key(bundleID: hit.bundleID, sentence: hit.word.sentence.text, word: hit.word.word, at: point)
        if key == lastLookedUp { return .quiet(.samePlace) }
        return .word(hit, request: request, key: key)
    }

    private func accept(
        _ read: Recognition, context: PendingContext?, request: CaptureRequest, policy: HoverPolicy, point: CGPoint
    ) -> Outcome {
        if let refusal = refusal(bundleID: read.bundleID, word: read.word.word, policy: policy) { return .quiet(refusal) }
        // Screen Only's site rule asked again of the window actually captured, by the owner the capture named.
        if policy.readingMode == .screenOnly, policy.refusesUnnamedPage(in: read.bundleID) { return .quiet(.excludedSite) }
        let key = Self.key(bundleID: read.bundleID, sentence: read.word.sentence.text, word: read.word.word, at: point)
        if key == lastLookedUp { return .quiet(.samePlace) }
        return .recognised(read, request: request, key: key, context: context)
    }

    /// Cancellation, the owner — checked again on the word read, since the recogniser reports the *window's* owner — and
    /// the script, which could not be asked before the word was read: hover only — a selection the reader asked for by the
    /// shortcut is looked up in any script.
    private func refusal(bundleID: String?, word: String, policy: HoverPolicy) -> HoverRefusal? {
        guard !Task.isCancelled else { return .cancelled }
        if let refusal = CaptureAuthorization.refusal(bundleID: bundleID, policy: policy) { return refusal }
        return policy.allows(word) ? nil : .scriptNotAllowed
    }

    /// **Whether a window of XDict's takes no click** — the hover notice and the popover's anchor (`ignoresMouseEvents`):
    /// such a window carries no reader text, so hover looks through it (`PointerWindow.withoutClickThrough`). Told by the
    /// window itself, so a new overlay of the same kind needs no list kept in step.
    public static func passesClicksThrough(_ windowID: UInt32, among windows: [NSWindow]) -> Bool {
        windowID != 0 && windows.first { $0.windowNumber == Int(windowID) }?.ignoresMouseEvents == true
    }

    func remember(_ key: String) { lastLookedUp = key }

    func forget(_ key: String) { if lastLookedUp == key { lastLookedUp = nil } }

    func endHover() { lastLookedUp = nil }

    /// **The lane's health, after each read through it**: a wedge reported once, its recovery once.
    private func noteLane() {
        switch source.laneState() {
        case .stuck(_, let blocked):
            guard !laneStuck else { return }
            log.fault("hover: the Accessibility lane has been blocked for \(blocked.components.seconds, privacy: .public) s")
            setHealth(lane: true, capture: captureStuck, blocked: blocked)
        case .idle, .running:
            guard laneStuck else { return }
            log.notice("hover: the Accessibility lane answers again")
            setHealth(lane: false, capture: captureStuck, blocked: nil)
        }
    }

    /// Identifies the word, the app and roughly where it was, so the same word twice in a sentence is two hovers but
    /// resting on one is one. The sentence enters only as a hash, compared in memory with the next read's and never kept
    /// past it: an identity, not a record (ADR-0014 decision 9).
    nonisolated static func key(_ hit: PointerWordReader.Hit, at point: CGPoint) -> String {
        key(bundleID: hit.bundleID, sentence: hit.word.sentence.text, word: hit.word.word, at: point)
    }

    nonisolated static func key(bundleID: String?, sentence: String, word: String, at point: CGPoint) -> String {
        let place = bundleID ?? "—"
        let context = String(sentence.hashValue, radix: 16)
        // XiaolaiDict's 8-point cell: a grid that groups a resting pointer's positions.
        return "\(place)|\(context)|\(word)@\(Int(point.x) / 8)x\(Int(point.y) / 8)"
    }
}

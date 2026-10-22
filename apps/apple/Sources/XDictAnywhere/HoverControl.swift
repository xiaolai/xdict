import CoreGraphics
import Foundation
import Observation
import XDictCapture
import XDictCaptureMac
import XDictTokens

/// **Capture's distances, from the tokens** (ADR-0014 decisions 5 and 11): the capture targets may not import the tokens,
/// so the composition layer builds their values here and hands them in.
public enum CaptureTolerances {
    /// How far from a word a resting pointer may be and still mean it — one rule for every capture path.
    public static let hit: HitTolerance = {
        guard let tolerance = HitTolerance(horizontal: Tokens.Capture.hitAcross, vertical: Tokens.Capture.hitDown) else {
            preconditionFailure("the capture tokens are not a valid hit tolerance")
        }
        return tolerance
    }()
    /// How far a resting pointer may drift and still be resting.
    public static let restDrift: CGFloat = Tokens.Capture.restDrift
    /// **Every distance the recogniser measures with** (plan-capture WI-4): the hit tolerance, the strip it reads and how it
    /// grows, the tiling slacks in band pixels, and how far two readings of a window's frame may disagree.
    public static let metrics = CaptureMetrics(
        hit: hit, restTolerance: restDrift,
        strip: StripMetrics(initialHeight: Tokens.Capture.stripStart, growthStep: Tokens.Capture.stripStep,
                            maximumHeight: Tokens.Capture.stripMost),
        tiling: TilingMetrics(edgeSlack: Tokens.Capture.tileEdgeSlack, holeSlack: Tokens.Capture.tileHoleSlack),
        frameDrift: Tokens.Capture.frameDrift,
        label: LabelSlack(shift: Tokens.Capture.labelShift, smaller: Tokens.Capture.labelSmaller))
}

/// **The Screen Recording row's state, as kinds** (plan-capture WI-4; the view layer words them).
public enum ScreenRecordingRow: Sendable, Equatable {
    /// The row has not been used in this run and macOS reports no standing grant: nothing was asked.
    case notSetUp
    case allowed
    /// macOS says no; only System Settings changes it now.
    case notAllowed
    /// The probe failed for a reason that is not a refusal.
    case couldNotTell
}

/// **Everything the reader can do to hover, and the one place each of those values lives** (ported from XiaolaiDict's
/// `HoverControl`, plan-capture WI-3). Every member here was once a defect about identity — a fresh value per call, or two
/// copies — so the watcher is built here and handed closures onto these values, never copies, and a decision is made
/// against what is true at decision time:
///
/// - `pauseSwitch`: **the pause the menu offers and the gate reads — one value** (XiaolaiDict's reader built a fresh,
///   never-paused one per call, and its pause reached nothing for months under a green suite);
/// - `policy`: the reader's, loaded once and saved on change, never decoded on the mouse-move path; its scripts are not
///   stored but read from `scripts` at decision time (`effectivePolicy`), so they follow the enabled dictionaries;
/// - `requests`: the app's one numbering, shared with the shortcut, the Service and the menu (ADR-0014 d.4);
/// - `notice`: the lane or the capture stuck, or the pixels needing Screen Recording, as the consumer's kind
///   (`CaptureNotice`), observed so Settings can say it;
/// - `contextSession`: **the one ephemeral session a presented sentence lives in** (ADR-0014 d.9), capture's own, whose
///   book the reader starts its pending contexts in (d.8), so the consumer finds a presented term's handle there;
/// - `screenRecording`: the Screen Recording row, **the only thing that asks** (d.7), through the one `ScreenRecordingAccess`
///   the recogniser reads.
@MainActor
@Observable
public final class HoverControl {
    /// The watcher, made on first use so its closures can read `self`.
    @ObservationIgnored public private(set) lazy var watcher = makeWatcher()
    /// The app's one book of capture requests, every trigger's.
    @ObservationIgnored public let requests: CaptureRequests

    public private(set) var pauseSwitch = HoverPause()
    /// The reader's policy as stored: its scripts are always nil (see `effectivePolicy`).
    public private(set) var policy: HoverPolicy
    /// Whether the lane is answering, as the watcher last said.
    public private(set) var captureHealth = CaptureHealth.answering
    /// Whether the watcher actually holds its monitors — **read back from the watcher**, not assumed from the setting:
    /// starting can fail, and a control that says "on" for a hover that is not running is wrong.
    public private(set) var isWatching = false
    /// The Screen Recording row, as last read. Read only on the row's own refresh, and never by calling anything that can
    /// prompt before the row was used (`ScreenRecordingAccess`).
    public private(set) var screenRecording = ScreenRecordingRow.notSetUp
    /// A hover needed the pixels and Screen Recording was not there for it, in this run.
    public private(set) var neededScreenRecording = false
    /// **Where a notice the watcher tells is shown by the pointer** (owner's report, 2026-10-19: a miss showed nothing):
    /// set by the consumer, which words and draws it. Kinds only, and at most once a while per kind (`HoverNoticeThrottle`).
    @ObservationIgnored public var showBriefNotice: (@MainActor (CaptureNotice) -> Void)?
    @ObservationIgnored private var briefs = HoverNoticeThrottle()
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    /// The reader's setting, as stored (`isEnabled`).
    private var enabled: Bool
    /// A reader's launch asked the watcher to start and it did not (`HoverWatcher.start` could not install its monitors).
    private var startFailed = false
    /// Which launch this is, once `startAtLaunch` said: until then, and in a driven run, nothing starts the watcher.
    @ObservationIgnored private var launch: HoverLaunch?
    /// The presented request's context, and nothing else of it: memory only, cleared when presentation closes.
    @ObservationIgnored public let contextSession = CaptureContextSession()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: HoverPolicyStore
    @ObservationIgnored private let source: any PointerWordSource
    @ObservationIgnored private let screen: ScreenRecordingAccess
    @ObservationIgnored private let scripts: @MainActor () -> Set<CaptureScript>?
    /// Starts the watcher and says whether it holds its monitors: the system's (`systemStart`), or a test's, which can
    /// fail where the system's monitors never do.
    @ObservationIgnored private let startWatcher: @MainActor (HoverWatcher) -> Bool
    /// Warms the recogniser in the background (`ScreenTextRecogniser.warmUp`), or a test's count.
    @ObservationIgnored private let warmUpRecognition: @MainActor () -> Void
    /// Whether this launch has warmed it: once per launch, however often the watcher restarts.
    @ObservationIgnored private var warmed = false
    /// **Vision kept warm while the watcher runs** (`RecognitionKeepWarm`): its models are dropped after minutes idle and
    /// reloading them took 24 s, so a launch's warm-up alone left the first hover after a pause stalled.
    @ObservationIgnored public let keepWarm: RecognitionKeepWarm

    static let enabledKey = "hoverLookupEnabled"

    /// **The watcher started on the system's events**, read back from it: what the app runs.
    public static func systemStart(_ watcher: HoverWatcher) -> Bool {
        watcher.start()
        return watcher.isWatching
    }

    /// `scripts` derives the allowed scripts from the enabled dictionaries (`HoverScripts`), at decision time; `screen` is
    /// the one owner of the Screen Recording grant; `source` is the real screen through the one lane and that grant (nil),
    /// or a test's.
    public init(
        defaults: UserDefaults, requests: CaptureRequests, screen: ScreenRecordingAccess = .system,
        source: (any PointerWordSource)? = nil, scripts: @escaping @MainActor () -> Set<CaptureScript>? = { nil },
        startWatcher: @escaping @MainActor (HoverWatcher) -> Bool = HoverControl.systemStart,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        warmUpRecognition: @escaping @MainActor () -> Void = { ScreenTextRecogniser.warmUp() },
        keepWarm: RecognitionKeepWarm? = nil
    ) {
        self.keepWarm = keepWarm ?? RecognitionKeepWarm()
        self.startWatcher = startWatcher
        self.warmUpRecognition = warmUpRecognition
        self.now = now
        self.defaults = defaults
        self.requests = requests
        self.screen = screen
        self.source = source ?? SystemPointerWords(metrics: CaptureTolerances.metrics, screen: screen)
        self.scripts = scripts
        let store = HoverPolicyStore(defaults: defaults)
        self.store = store
        policy = store.load()
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private func makeWatcher() -> HoverWatcher {
        let watcher = HoverWatcher(
            policy: { [weak self] in self?.effectivePolicy ?? .shipped },
            pause: { [weak self] in self?.pauseSwitch ?? HoverPause() },
            requests: requests, source: source, contexts: contextSession.pending, restTolerance: CaptureTolerances.restDrift)
        watcher.onCaptureHealth = { [weak self] in self?.captureHealth = $0 }
        watcher.onNotice = { [weak self] notice in self?.told(notice) }
        return watcher
    }

    /// A notice for a hover that still stands: kept for Settings where it is the grant's, and shown by the pointer unless
    /// the same kind was shown a moment ago.
    private func told(_ notice: CaptureNotice) {
        if notice == .screenRecordingNeeded { neededScreenRecording = true }
        guard briefs.allows(notice, at: now()) else { return }
        showBriefNotice?(notice)
    }

    /// The policy the gate decides with: the reader's, with the scripts the enabled dictionaries allow now.
    public var effectivePolicy: HoverPolicy {
        var effective = policy
        effective.settleMilliseconds = settle.milliseconds
        effective.allowedScripts = scripts()
        return effective
    }

    /// The scripts hover looks up now, or nil for every script — what Settings shows.
    public var allowedScripts: Set<CaptureScript>? { scripts() }

    /// What the reader should be told about hover, as a kind the view layer words: a stuck read first, then the pixels
    /// needing a grant the row has not shown to be there.
    public var notice: CaptureNotice? {
        if captureHealth != .answering { return .captureStuck }
        return neededScreenRecording && screenRecording != .allowed ? .screenRecordingNeeded : nil
    }

    /// **The row is shown**: what the grant is now — without calling anything that can prompt, unless the row was used in
    /// this run or macOS reports a standing grant.
    public func refreshScreenRecording() async {
        screenRecording = Self.row(await screen.captureState())
    }

    /// **The reader used the row**: the only request (macOS prompts once ever; after that the reader is sent to System
    /// Settings), and the answer shown.
    public func setUpScreenRecording() async {
        screenRecording = Self.row(Self.state(await screen.setUp()))
    }

    private static func state(_ probe: PermissionProbe) -> ScreenRecordingState {
        switch probe {
        case .granted: .granted
        case .declined: .declined
        case .couldNotTell: .couldNotTell
        }
    }

    private static func row(_ state: ScreenRecordingState) -> ScreenRecordingRow {
        switch state {
        case .notSetUp: .notSetUp
        case .granted: .allowed
        case .declined: .notAllowed
        case .couldNotTell: .couldNotTell
        }
    }

    /// Whether the reader has hover on: on for a reader who never chose, remembered for one who did, **through the
    /// injected suite**, never `.standard`. Held here as well as stored, so a view reading it redraws when it changes.
    public var isEnabled: Bool {
        get { enabled }
        set {
            enabled = newValue
            defaults.set(newValue, forKey: Self.enabledKey)
        }
    }

    /// **What Settings' switch and the menu-bar pause group show**: the reader's setting, not whether this run watches —
    /// a driven run never does (`startAtLaunch`), and its menu said "Hover Is Off in Settings" with hover on (UI tour,
    /// 2026-10-19). Except **a start that failed says off**, which is what is true; the switch then asks again.
    public var isOn: Bool { isEnabled && !startFailed }

    /// **The key and the gesture the reader actually has**, read-only, for the setup board's line (plan-setup-v2
    /// WI-4): the sentence's verb carries the gesture ("hold" or "tap twice"), so it takes the key's own symbol.
    public var keySymbol: String { policy.modifier.symbol }

    /// Whether the reader's gesture is a double tap rather than a hold.
    public var isDoubleTap: Bool { policy.gesture == .doubleTap }

    public var isPaused: Bool { pauseSwitch.isPaused(at: .now) }

    public func pause(for duration: Duration) { pauseSwitch.pause(for: duration, from: .now) }
    public func resume() { pauseSwitch.resume() }

    /// Changing the policy saves it and takes effect immediately: the watcher reads this property.
    public func setPolicy(_ policy: HoverPolicy) {
        var stored = policy
        stored.allowedScripts = nil
        self.policy = stored
        store.save(stored)
    }

    // MARK: - Excluded sites and the rest time (Settings ▸ General)

    /// The most sites the reader may list: a list typed by hand, bounded so a decision over it stays cheap.
    public static let excludedSiteLimit = 500

    /// The sites the reader excluded, as stored hosts, in one order.
    public var excludedSites: [String] { policy.excludedHosts.sorted() }

    /// **The reader typed a site to exclude**: a name or a pasted address, kept as its host (`HoverPolicy.siteHost`) in
    /// the one stored policy, which the gate reads at once. What is not a site is refused and nothing is stored.
    public func addExcludedSite(_ typed: String) -> ExcludedSiteAnswer {
        guard let host = HoverPolicy.siteHost(fromTyped: typed) else { return .notASite }
        // **One label is too broad**: `com` would cover every site under it. An IPv6 literal is an address, not a label.
        guard host.contains(".") || host.contains(":") else { return .tooBroad }
        // A list saved before hosts were reduced may hold a whole address: compared as the host it names.
        let stored = Set(policy.excludedHosts.map { HoverPolicy.siteHost(fromTyped: $0) ?? HoverPolicy.normalisedHost($0) })
        guard !stored.contains(host) else { return .alreadyExcluded(host) }
        guard policy.excludedHosts.count < Self.excludedSiteLimit else { return .listFull }
        var changed = policy
        changed.excludedHosts.insert(host)
        setPolicy(changed)
        return .added(host)
    }

    public func removeExcludedSite(_ host: String) {
        var changed = policy
        changed.excludedHosts.remove(host)
        setPolicy(changed)
    }

    /// The rest the picker shows: the stored one when it is exactly one of the choices, else the shipped rest — the one
    /// the gate decides with too (`HoverPolicyStore.load`, `effectivePolicy`), so the picker and the watcher agree.
    /// Never the nearest choice: arithmetic on a stored value trapped on `Int.min` (verifier, 2026-10-19).
    public var settle: HoverPolicy.Settle {
        HoverPolicy.Settle(rawValue: policy.settleMilliseconds) ?? HoverPolicy.Settle.standard
    }

    public func setSettle(_ settle: HoverPolicy.Settle) {
        var changed = policy
        changed.settleMilliseconds = settle.milliseconds
        setPolicy(changed)
    }

    /// Starts watching where the reader has hover on. Called once there is a popover to present into — never in an
    /// instrument run.
    /// **The one way hover starts at launch**: never in a driven run, never when the reader turned it off.
    public func startAtLaunch(_ launch: HoverLaunch) {
        self.launch = launch
        guard launch == .reader, isEnabled else { return }
        start()
    }

    /// **Takes the value asked for**, rather than inverting what is stored: asked for on against a failed start, it
    /// tries again. **Only a reader's launch starts the watcher**: in a driven run the switch stores the setting and
    /// nothing more, so a key the instrument holds never opens a lookup.
    public func setEnabled(_ on: Bool) {
        isEnabled = on
        guard on else {
            watcher.stop()
            keepWarm.stop()
            isWatching = false
            startFailed = false
            return
        }
        if launch == .reader { start() }
    }

    private func start() {
        isWatching = startWatcher(watcher)
        startFailed = !isWatching
        // **The recogniser warmed once, once hover watches in a reader's launch** — never in a driven run (only a
        // reader's launch reaches here: `startAtLaunch`, `setEnabled`), never with hover off or a start that failed.
        // Fire-and-forget: hover's start does not wait.
        if isWatching, !warmed {
            warmed = true
            warmUpRecognition()
        }
        // And kept warm while it watches, in the same launches only.
        if isWatching { keepWarm.start() } else { keepWarm.stop() }
    }
}

/// **How often a brief hover notice may be shown by the pointer**: once per kind within `interval`, so a reader
/// double-tapping blank space, or resting on it with the key held, is told once rather than at every try.
public struct HoverNoticeThrottle: Sendable {
    /// A duration, not a design value: long enough that repeated tries read as one answer, short enough that the next
    /// deliberate try is answered.
    public static let interval: Duration = .seconds(2)
    private var shown: [CaptureNotice: ContinuousClock.Instant] = [:]

    public init() {}

    /// Whether `notice` may be shown at `now`; a yes is remembered as shown.
    public mutating func allows(_ notice: CaptureNotice, at now: ContinuousClock.Instant) -> Bool {
        if let last = shown[notice], now - last < Self.interval { return false }
        shown[notice] = now
        return true
    }
}

/// What adding a site to exclude did, as kinds (the view layer words them).
public enum ExcludedSiteAnswer: Sendable, Equatable {
    case added(String)
    case alreadyExcluded(String)
    /// Neither a host name nor an address holding one.
    case notASite
    /// One label, such as `com`: it would cover every site under it.
    case tooBroad
    /// The list already holds `HoverControl.excludedSiteLimit` sites.
    case listFull
}

/// **Which launch this is** (plan-capture WI-3): the reader's, or one a development instrument drives, in which hover is
/// not started, so a key the instrument holds never opens a lookup it did not ask for. A type rather than a `Bool`, so
/// the decision cannot be inverted by a stray `!` where it is made.
public enum HoverLaunch: Sendable, Equatable {
    case reader
    case instrument

    /// An instrument run when any of `instrumentFlags` is one of `arguments`, exactly.
    public static func of(arguments: [String], instrumentFlags: [String]) -> HoverLaunch {
        instrumentFlags.contains(where: arguments.contains) ? .instrument : .reader
    }
}

/// **The pause group of the menu-bar menu, as kinds** (XiaolaiDict's `HoverPauseMenu`; its words are the view layer's):
/// offered only with hover on, and a paused hover says when it comes back.
public enum HoverPauseMenu {
    public enum Entry: Equatable, Sendable {
        /// The parent of the pause lengths (`HoverPause.durations`).
        case pause
        /// A line that does nothing: when hover comes back by itself.
        case resumesAt(Date)
        case resume
        /// Hover is switched off in Settings, so there is nothing to pause — said, rather than left out.
        case hoverIsOff
    }

    public static func entries(hoverIsOn: Bool, pausedUntil: Date?, now: Date) -> [Entry] {
        guard hoverIsOn else { return [.hoverIsOff] }
        guard let pausedUntil, now < pausedUntil else { return [.pause] }
        return [.resumesAt(pausedUntil), .resume]
    }

    /// The menu's entries from the control: the reader's setting (`isOn`, not whether this run watches) and its one pause.
    @MainActor
    public static func entries(for hover: HoverControl, now: Date) -> [Entry] {
        entries(hoverIsOn: hover.isOn, pausedUntil: hover.pauseSwitch.until, now: now)
    }
}

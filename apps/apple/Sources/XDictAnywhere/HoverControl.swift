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
/// - `notice`: the lane stuck, as the consumer's kind (`CaptureNotice.captureStuck`), observed so Settings can say it.
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

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: HoverPolicyStore
    @ObservationIgnored private let source: any PointerWordSource
    @ObservationIgnored private let scripts: @MainActor () -> Set<CaptureScript>?

    static let enabledKey = "hoverLookupEnabled"

    /// `scripts` derives the allowed scripts from the enabled dictionaries (`HoverScripts`), at decision time; `source` is
    /// the real screen through the one lane, or a test's.
    public init(
        defaults: UserDefaults, requests: CaptureRequests,
        source: any PointerWordSource = SystemPointerWords(tolerance: CaptureTolerances.hit),
        scripts: @escaping @MainActor () -> Set<CaptureScript>? = { nil }
    ) {
        self.defaults = defaults
        self.requests = requests
        self.source = source
        self.scripts = scripts
        let store = HoverPolicyStore(defaults: defaults)
        self.store = store
        policy = store.load()
    }

    private func makeWatcher() -> HoverWatcher {
        let watcher = HoverWatcher(
            policy: { [weak self] in self?.effectivePolicy ?? .shipped },
            pause: { [weak self] in self?.pauseSwitch ?? HoverPause() },
            requests: requests, source: source, restTolerance: CaptureTolerances.restDrift)
        watcher.onCaptureHealth = { [weak self] in self?.captureHealth = $0 }
        return watcher
    }

    /// The policy the gate decides with: the reader's, with the scripts the enabled dictionaries allow now.
    public var effectivePolicy: HoverPolicy {
        var effective = policy
        effective.allowedScripts = scripts()
        return effective
    }

    /// The scripts hover looks up now, or nil for every script — what Settings shows.
    public var allowedScripts: Set<CaptureScript>? { scripts() }

    /// What the reader should be told about hover, as a kind the view layer words.
    public var notice: CaptureNotice? { captureHealth == .answering ? nil : .captureStuck }

    /// Whether the reader has hover on: on for a reader who never chose, remembered for one who did, **through the
    /// injected suite**, never `.standard`.
    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

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

    /// Starts watching where the reader has hover on. Called once there is a popover to present into — never in an
    /// instrument run.
    public func startIfEnabled() {
        guard isEnabled else { return }
        watcher.start()
        isWatching = watcher.isWatching
    }

    /// **Takes the value asked for**, rather than inverting what is stored: asked for on against a failed start, it
    /// tries again.
    public func setEnabled(_ on: Bool) {
        isEnabled = on
        if on { watcher.start() } else { watcher.stop() }
        isWatching = watcher.isWatching
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
}

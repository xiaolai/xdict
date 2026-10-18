import AppKit
import XDictBase
import XDictCapture
import os

/// What `HoverWatcher` needs of a reader — the seam its event-sequence tests replace.
@MainActor
protocol HoverReading: AnyObject {
    /// Called when the one lane stops answering, and again when it answers.
    var onCaptureHealth: (@MainActor (CaptureHealth) -> Void)? { get set }
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

/// Whether hover's reads are answering. **Stuck is the lane's** (ADR-0014 decision 6): a read blocked inside another
/// process's Accessibility call cannot be cancelled, every later read waits behind it, and the reader is told rather than
/// left with a hover that silently does nothing. The consumer words it (`CaptureNotice.captureStuck`).
public enum CaptureHealth: Sendable, Equatable {
    case answering
    /// Blocked for this long when it was noticed.
    case stuck(for: Duration)
}

/// **One hover: the gate, then who owns the pixel, then the site and the text in one lane job** (ported from XiaolaiDict's
/// `HoverReader`, plan-capture WI-3; the recogniser and its guard are WI-4's, so a hover Accessibility cannot read finds
/// nothing here).
///
/// `HoverPolicy` decides whether to look at all — and it is asked **first**, so a reader who is simply reading never pays
/// for Accessibility. The text is read **only** through `PointerWordSource.readUnlessRefused` (WI-2): the site check and the
/// read are one job, so an excluded or unreadable site reads no text.
@MainActor
public final class HoverReader: HoverReading {
    private let log = Logger(subsystem: XDictIdentity.app, category: "hover")
    private let source: any PointerWordSource
    private let policy: @MainActor () -> HoverPolicy
    private let pause: @MainActor () -> HoverPause
    /// The whole Accessibility read's budget.
    private let budget: Duration
    var onCaptureHealth: (@MainActor (CaptureHealth) -> Void)?
    /// The lane's wedge has been reported, and not yet its recovery.
    private var reportedStuck = false

    /// The word the last hover looked up, so resting on it does not look it up again. **Written when a word is
    /// delivered**, by `remember`; **cleared when the hover ends** (the key up, no tap) and when its presentation never
    /// drew (`forget`). A key, not a record: it is compared only with the next read's, in memory.
    var lastLookedUp: String?

    public init(
        policy: @escaping @MainActor () -> HoverPolicy, pause: @escaping @MainActor () -> HoverPause = { HoverPause() },
        source: any PointerWordSource, budget: Duration = PointerWordReader.budget
    ) {
        self.policy = policy
        self.pause = pause
        self.source = source
        self.budget = budget
    }

    /// Why a hover the gate allowed found no word: typed, and metadata only.
    public enum Nothing: Sendable, Equatable {
        /// Accessibility named no element at the point (or is not granted).
        case noTarget(PointerWordReader.TargetMiss)
        /// The element named had no word there, or a request failed.
        case miss(PointerWordReader.Miss)
    }

    public enum Outcome: Sendable, Equatable {
        /// A word, the request it was read for, and the key that suppresses it once delivered.
        case word(PointerWordReader.Hit, request: CaptureRequest, key: String)
        /// The gate, or a refusal after the read. Ordinary, and not worth showing.
        case quiet(HoverRefusal)
        /// The gate said yes and nothing could be read.
        case nothing(Nothing)
    }

    public func read(
        at point: CGPoint, modifiersHeld: Set<HoverModifier>, tappedTwice: Bool, pointerStillFor: Duration,
        begin: @MainActor () -> CaptureRequest
    ) async -> Outcome {
        let policy = policy()
        // **A completed double-tap is a new request, and says so**: the same word tapped twice in a row is asked again.
        if tappedTwice { lastLookedUp = nil }
        // **The cheap refusals first, before any IPC.**
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

        // **Our own window first, from the compositor**, before Accessibility is asked anything.
        let windows = source.listedWindows()
        if PointerWindow.ours(at: point, in: windows, ours: getpid()) { return .quiet(.samePlace) }
        let target: PointerWordReader.Target
        switch await source.target(at: point, windows: { windows }) {
        case .none(let why):
            noteHealth()
            return .nothing(.noTarget(why))
        case .ourOwnWindow:
            return .quiet(.samePlace)
        case .found(let found):
            if let refusal = CaptureAuthorization.refusal(bundleID: found.bundleID, policy: policy) { return .quiet(refusal) }
            target = found
        }
        // **A reader who moved on starts nothing new.**
        guard !Task.isCancelled else { return .quiet(.cancelled) }

        let gated = await source.readUnlessRefused(at: point, in: target, refuses: { policy.refuses($0) }, budget: budget)
        noteHealth()
        switch gated {
        case .refused:
            return .quiet(.excludedSite)
        case .read(.hit(let hit)):
            return accept(hit, request: request, policy: policy, point: point)
        case .read(.miss(let miss)):
            return .nothing(.miss(miss))
        case .read(.cancelled):
            return .quiet(.cancelled)
        }
    }

    /// **The one place a read becomes an answer**: cancellation, then the refusals that need the word itself.
    private func accept(_ hit: PointerWordReader.Hit, request: CaptureRequest, policy: HoverPolicy, point: CGPoint) -> Outcome {
        guard !Task.isCancelled else { return .quiet(.cancelled) }
        if let refusal = CaptureAuthorization.refusal(bundleID: hit.bundleID, policy: policy) { return .quiet(refusal) }
        // **The script, which could not be asked before the word was read**: hover only — a selection the reader asked
        // for by the shortcut is looked up in any script.
        if !policy.allows(hit.word.word) { return .quiet(.scriptNotAllowed) }
        let key = Self.key(hit, at: point)
        if key == lastLookedUp { return .quiet(.samePlace) }
        return .word(hit, request: request, key: key)
    }

    func remember(_ key: String) { lastLookedUp = key }

    func forget(_ key: String) { if lastLookedUp == key { lastLookedUp = nil } }

    func endHover() { lastLookedUp = nil }

    /// **The lane's health, after each read through it**: a wedge reported once, its recovery once.
    private func noteHealth() {
        switch source.laneState() {
        case .stuck(_, let blocked):
            guard !reportedStuck else { return }
            reportedStuck = true
            log.fault("hover: the Accessibility lane has been blocked for \(blocked.components.seconds, privacy: .public) s")
            onCaptureHealth?(.stuck(for: blocked))
        case .idle, .running:
            guard reportedStuck else { return }
            reportedStuck = false
            log.notice("hover: the Accessibility lane answers again")
            onCaptureHealth?(.answering)
        }
    }

    /// Identifies the word, the app and roughly where it was, so the same word twice in a sentence is two hovers but
    /// resting on one is one. The sentence enters only as a hash, compared in memory with the next read's and never kept
    /// past it: an identity, not a record (ADR-0014 decision 9).
    nonisolated static func key(_ hit: PointerWordReader.Hit, at point: CGPoint) -> String {
        let place = hit.bundleID ?? "—"
        let context = String(hit.word.sentence.text.hashValue, radix: 16)
        // XiaolaiDict's 8-point cell: a grid that groups a resting pointer's positions.
        return "\(place)|\(context)|\(hit.word.word)@\(Int(point.x) / 8)x\(Int(point.y) / 8)"
    }
}

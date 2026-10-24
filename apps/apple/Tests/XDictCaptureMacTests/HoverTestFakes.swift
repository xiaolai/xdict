import AppKit
import ApplicationServices
import Foundation
import Synchronization
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// The stand-ins hover's behavioural tests share — **one spelling each** (ported from XiaolaiDict's `HoverTestFakes`, plan-capture
/// WI-3): two copies of a fake drift, and then a test proves something about the copy.

/// Events a test emits by hand.
@MainActor
final class ScriptedHoverEvents: HoverEventSource {
    private var handler: (@MainActor (HoverEvent) -> Void)?
    var installs = true
    private(set) var stops = 0

    func start(_ handler: @escaping @MainActor (HoverEvent) -> Void) -> Bool {
        guard installs else { return false }
        self.handler = handler
        return true
    }

    func stop() {
        handler = nil
        stops += 1
    }

    func emit(_ event: HoverEvent) { handler?(event) }

    /// Down, up, down with the event's own times.
    func doubleTap(from instant: TimeInterval, modifier: HoverModifier = .option) {
        emit(.modifiers([modifier], at: instant, location: nil))
        emit(.modifiers([], at: instant + 0.08, location: nil))
        emit(.modifiers([modifier], at: instant + 0.2, location: nil))
    }
}

/// The system's event monitors, recorded: which kinds were installed globally and locally, the local handlers (to hand an
/// event to), and how many were removed. `refuseLocal` makes every local install fail.
@MainActor
final class RecordingMonitors {
    private(set) var global: [UInt64] = []
    private(set) var local: [(mask: UInt64, handler: (NSEvent) -> NSEvent?)] = []
    private(set) var removed = 0
    var refuseLocal = false

    var monitors: HoverMonitors {
        HoverMonitors(
            addGlobal: { [self] mask, _ in
                global.append(mask.rawValue)
                return mask.rawValue
            },
            addLocal: { [self] mask, handler in
                guard !refuseLocal else { return nil }
                local.append((mask.rawValue, handler))
                return mask.rawValue
            },
            remove: { [self] _ in removed += 1 })
    }
}

/// Where the pointer is and what is held, set by the test.
@MainActor
final class ScriptedPointer {
    var at = UpPoint(x: 100, y: 100)
    var held: Set<HoverModifier> = []
    func read() -> (UpPoint, Set<HoverModifier>) { (at, held) }
}

/// A settle timer the test fires.
@MainActor
final class ManualSchedule {
    private var pending: [Int: @MainActor () -> Void] = [:]
    private var serial = 0

    var armed: Int { pending.count }

    func schedule(_ delay: Duration, _ work: @escaping @MainActor () -> Void) -> HoverWatcher.Cancel {
        serial += 1
        let mine = serial
        pending[mine] = work
        return { [weak self] in self?.pending[mine] = nil }
    }

    /// Runs whatever is armed, as the timer would.
    func fire() {
        let due = pending
        pending.removeAll()
        for key in due.keys.sorted() { due[key]?() }
    }
}

/// A reader whose reads end when the test says so.
@MainActor
final class ScriptedHoverReader: HoverReading {
    struct Ask: Equatable {
        let point: CGPoint
        let held: Set<HoverModifier>
        let tapped: Bool
        let request: CaptureRequest
    }

    var onCaptureHealth: (@MainActor (CaptureHealth) -> Void)?
    var onCaptureReleased: (@MainActor () -> Void)?
    private(set) var asks: [Ask] = []
    private(set) var remembered: [String] = []
    private(set) var forgotten: [String] = []
    private(set) var hoversEnded = 0
    private var waiting: [CheckedContinuation<HoverReader.Outcome, Never>] = []

    var pendingReads: Int { waiting.count }

    func read(
        at point: CGPoint, modifiersHeld: Set<HoverModifier>, tappedTwice: Bool, pointerStillFor: Duration,
        begin: @MainActor () -> CaptureRequest
    ) async -> HoverReader.Outcome {
        asks.append(Ask(point: point, held: modifiersHeld, tapped: tappedTwice, request: begin()))
        return await withCheckedContinuation { waiting.append($0) }
    }

    func remember(_ key: String) { remembered.append(key) }
    func forget(_ key: String) { forgotten.append(key) }
    func endHover() { hoversEnded += 1 }

    /// Ends the oldest read in flight with a word, for the request the newest ask was given.
    func answerWord(_ text: String = "hold", bounds: ReadBounds? = nil) {
        guard let ask = asks.last else { return }
        answer(.word(HoverFixtures.hit(text, bounds: bounds), request: ask.request, key: "key-\(text)-\(ask.request.number)"))
    }

    func answer(_ outcome: HoverReader.Outcome) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: outcome)
    }
}

/// The app's side: a sink that takes every term it is handed and records it.
final class RecordingSink: CaptureSink {
    let delivered = Mutex<[CaptureDelivery]>([])
    func deliver(_ delivery: CaptureDelivery) -> CaptureDeliveryAnswer {
        delivered.withLock { $0.append(delivery) }
        return .accepted
    }
    var terms: [String] { delivered.withLock { $0.map(\.term.term) } }
    var all: [CaptureDelivery] { delivered.withLock { $0 } }
}

/// A screen whose Accessibility answers what the test scripted — through the one combined job, as the real one.
final class ScriptedPointerWords: PointerWordSource, @unchecked Sendable {
    /// Read only after the test has set it up, from the one read in flight.
    var targetOutcome: PointerWordReader.TargetOutcome = .none(.nothingAtPointer)
    /// What the main actor's hit test of XDict's own application answers (`ownTarget`).
    var ownTargetOutcome: PointerWordReader.OwnTargetOutcome = .none(.nothingAtPointer)
    var readOutcome: PointerWordReader.Outcome = .miss(.noText(app: "TextEdit", role: nil))
    var hostReading: HostReading = .notWebContent
    var windows: [ListedWindow] = []
    var lane: LaneState = .idle
    /// Lane jobs: the hit tests and the reads asked through the one lane.
    private(set) var laneTargets = 0
    private(set) var reads = 0
    private(set) var textReads = 0
    /// What is under the point in XDict's own window, by view geometry (`ownView`): its controls, by default.
    var ownView: OwnView = .controls
    /// XDict's own work: the view checks (on the main thread, checked), and the Accessibility hit tests and reads.
    private(set) var ownViewChecks = 0
    private(set) var ownTargets = 0
    private(set) var ownReads = 0
    private(set) var ownWorkOffTheMainThread = 0
    /// What the recogniser answers (plan-capture WI-4), and whether it hangs until `finishCapture`. A window named here
    /// answers with its own result — the look-through reads XDict's window and then the app behind it in one hover.
    var recognition: Result<Recognition, RecognitionError> = .failure(.nothingUnderPointer)
    var recognitionsByWindow: [UInt32: Result<Recognition, RecognitionError>] = [:]
    var hangs = false
    private(set) var recognitions = 0
    private(set) var recognisedWindows: [ListedWindow] = []
    private let hung = Mutex<[CheckedContinuation<Void, Never>]>([])

    func listedWindows() -> [ListedWindow] { windows }

    func target(
        at point: CGPoint, windows: @escaping @Sendable () -> [ListedWindow], refusesOwner: @escaping @Sendable (pid_t) -> Bool
    ) async -> PointerWordReader.TargetOutcome {
        laneTargets += 1
        return targetOutcome
    }

    /// The look-through's own hit test: the app behind one of XDict's windows (`target(of:at:refusesOwner:)`).
    var behindTargetOutcome: PointerWordReader.TargetOutcome = .none(.nothingAtPointer)
    private(set) var behindTargets: [pid_t] = []

    func target(of owner: pid_t, at point: CGPoint) async -> PointerWordReader.TargetOutcome {
        behindTargets.append(owner)
        return behindTargetOutcome
    }

    func readUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: @escaping @Sendable (HostReading) -> Bool,
        budget: Duration
    ) async -> PointerWordReader.GatedOutcome {
        reads += 1
        if refuses(hostReading) { return .refused(hostReading) }
        textReads += 1
        return .read(readOutcome)
    }

    func ownView(at point: CGPoint) -> OwnView {
        ownViewChecks += 1
        if !Thread.isMainThread { ownWorkOffTheMainThread += 1 }
        return ownView
    }

    func ownTarget(at point: CGPoint) async -> PointerWordReader.OwnTargetOutcome {
        ownTargets += 1
        return ownTargetOutcome
    }

    func readOwnUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: @escaping @Sendable (HostReading) -> Bool,
        budget: Duration
    ) async -> PointerWordReader.GatedOutcome {
        ownReads += 1
        if refuses(hostReading) { return .refused(hostReading) }
        textReads += 1
        return .read(readOutcome)
    }

    func laneState() -> LaneState { lane }

    func recognise(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Recognition {
        recognitions += 1
        recognisedWindows.append(window)
        if hangs { await withCheckedContinuation { continuation in hung.withLock { $0.append(continuation) } } }
        return try (recognitionsByWindow[window.windowID] ?? recognition).get()
    }

    /// Lets every hung capture return.
    func finishCapture() {
        for continuation in hung.withLock({ taken in defer { taken = [] }; return taken }) { continuation.resume() }
    }
}

enum HoverFixtures {
    /// The tolerance a resting pointer may drift by, as XiaolaiDict measured it (2 pt; the app hands in its token).
    static let rest: CGFloat = 2

    /// A word read through the text-range dialect, its sentence the word itself.
    static func hit(_ text: String, bundleID: String = "com.apple.TextEdit", bounds: ReadBounds? = nil) -> PointerWordReader.Hit {
        guard let word = TextSegmenter.word(in: text, utf16Offset: 0) else { preconditionFailure("no word in \(text)") }
        return PointerWordReader.Hit(word: word, acquisition: .textRange, appName: "TextEdit", bundleID: bundleID, bounds: bounds)
    }

    /// An Accessibility target in an app that is not this one. The element is never asked anything: the scripted screen
    /// answers instead.
    static func target(bundleID: String = "com.apple.TextEdit") -> PointerWordReader.Target {
        PointerWordReader.Target(element: AXUIElementCreateApplication(getpid() + 1), appName: "TextEdit", bundleID: bundleID)
    }

    /// An Accessibility target in **this** process — XDict's own window, as `AXUIElementGetPid` names it.
    static func ownTarget(bundleID: String = "ai.xdict.app") -> PointerWordReader.Target {
        PointerWordReader.Target(element: AXUIElementCreateApplication(getpid()), appName: "XDict", bundleID: bundleID)
    }

    /// Lets already-started work run, for an assertion that something did **not** happen. It cannot prove an absence,
    /// only give the absence a fair chance to be broken: a slow machine can make it miss a defect, never invent one.
    @MainActor
    static func drain() async {
        for turn in 0..<250 {
            if turn < 200 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(1)) }
        }
    }

    /// Lets started work run until `condition` holds, a millisecond a turn, bounded so a failure ends rather than hangs.
    @MainActor
    static func settle(until condition: @MainActor () -> Bool) async {
        let end = ContinuousClock.now + Wait.patience
        while ContinuousClock.now < end {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

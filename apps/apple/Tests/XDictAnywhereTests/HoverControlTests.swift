import CoreGraphics
import Foundation
import Testing
import XDictAnywhere
import XDictCapture
@testable import XDictCaptureMac
import XDictTokens

/// A screen that answers nothing and counts what it was asked: no real Accessibility, no grant of this Mac's.
final class SilentPointerWords: PointerWordSource, @unchecked Sendable {
    var lane: LaneState = .idle
    private(set) var reads = 0
    func listedWindows() -> [ListedWindow] { [] }
    func target(at point: CGPoint, windows: @escaping @Sendable () -> [ListedWindow]) async -> PointerWordReader.TargetOutcome {
        .none(.nothingAtPointer)
    }
    func readUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: @escaping @Sendable (HostReading) -> Bool,
        budget: Duration
    ) async -> PointerWordReader.GatedOutcome {
        reads += 1
        return .read(.miss(.noText(app: "", role: nil)))
    }
    func laneState() -> LaneState { lane }
    func recognise(at point: CGPoint, window: ListedWindow, policy: HoverPolicy) async throws -> Recognition {
        throw RecognitionError.nothingUnderPointer
    }
}

/// Screen Recording's system calls, counted, never made. `@unchecked`: every count is read and written under `lock`.
final class CountedScreen: @unchecked Sendable {
    private let lock = NSLock()
    private var probed = 0
    private var requested = 0
    let answer: PermissionProbe
    let standing: Bool
    init(answer: PermissionProbe = .granted, standing: Bool = false) {
        self.answer = answer
        self.standing = standing
    }
    var probes: Int { lock.withLock { probed } }
    var requests: Int { lock.withLock { requested } }
    var access: ScreenRecordingAccess {
        ScreenRecordingAccess(probe: { self.lock.withLock { self.probed += 1 }; return self.answer },
                              preflight: { self.standing }, request: { self.lock.withLock { self.requested += 1 } })
    }
}

@MainActor
private func control(
    _ defaults: UserDefaults? = nil, screen: CountedScreen = CountedScreen(),
    scripts: @escaping @MainActor () -> Set<CaptureScript>? = { nil }
) throws -> HoverControl {
    let suite = try defaults ?? #require(UserDefaults(suiteName: "ai.xdict.tests.hover.\(UUID().uuidString)"))
    return HoverControl(defaults: suite, requests: CaptureRequests(), screen: screen.access, source: SilentPointerWords(),
                        scripts: scripts)
}

/// **The pause reaches the gate from the menu it is offered in** (XiaolaiDict's `HoverPauseWiringTests`, moved by name in
/// plan-capture WI-3). These test the wire, not the model: XiaolaiDict's pause was complete, unit-tested and connected to
/// nothing for months. `theDelegateCanBeBuiltTheWayTheAdaptorBuildsIt` is not moved: XDict's app is a SwiftUI `App`
/// with no delegate built through the Objective-C runtime.
@MainActor
struct HoverPauseWiringTests {
    /// A reader who pauses hover is not looked up for, through the control's own watcher. **The watcher is built first,
    /// on purpose**: a pause captured by value when the watcher is made would be missed.
    @Test func pausingTheAppSilencesItsOwnWatcher() async throws {
        let hover = try control()
        let watcher = hover.watcher
        hover.pause(for: .seconds(900))
        let outcome = await watcher.reader.read(
            at: .zero, modifiersHeld: [HoverPolicy.shipped.modifier], tappedTwice: false, pointerStillFor: .seconds(10),
            begin: { CaptureRequest(number: 0, trigger: .pointerGesture) })
        guard case .quiet(.paused) = outcome else {
            Issue.record("the watcher answered \(outcome) while paused — the pause is not wired to the gate")
            return
        }
    }

    /// And resuming takes it back, so the pause cannot strand a reader with a hover that quietly stopped working.
    @Test func resumingTakesItBack() throws {
        let hover = try control()
        hover.pause(for: .seconds(900))
        #expect(hover.isPaused)
        hover.resume()
        #expect(!hover.isPaused)
    }

    /// **A paused hover says so where the reader is looking**: the menu's entries are built from the control's own pause.
    @Test func thePausedStateIsVisibleInTheMenu() throws {
        let hover = try control()
        let now = Date.now
        #expect(HoverPauseMenu.entries(hoverIsOn: true, pausedUntil: hover.pauseSwitch.until, now: now) == [.pause])
        hover.pause(for: .seconds(900))
        let paused = HoverPauseMenu.entries(hoverIsOn: true, pausedUntil: hover.pauseSwitch.until, now: now)
        #expect(paused.last == .resume, "the menu offered \(paused)")
        #expect(paused.count == 2, "a paused hover is not said to be paused: \(paused)")
        #expect(HoverPauseMenu.entries(hoverIsOn: false, pausedUntil: nil, now: now) == [.hoverIsOff])
    }

    /// **And the policy, by the same argument**: the reader's modifier and rest reach the gate. Shift is held and the
    /// pointer has not rested: under the reader's policy that is `.stillMoving`, under the shipped one `.modifierNotHeld`.
    @Test func theReadersOwnPolicyIsTheOneTheGateUses() async throws {
        let hover = try control()
        let watcher = hover.watcher
        var chosen = HoverPolicy.shipped
        chosen.modifier = .shift
        chosen.settleMilliseconds = HoverPolicy.Settle.patient.milliseconds
        hover.setPolicy(chosen)
        let outcome = await watcher.reader.read(
            at: .zero, modifiersHeld: [.shift], tappedTwice: false, pointerStillFor: .zero,
            begin: { CaptureRequest(number: 0, trigger: .pointerGesture) })
        guard case .quiet(.stillMoving) = outcome else {
            Issue.record("the gate answered \(outcome) — it is still using the shipped policy")
            return
        }
    }

    /// What the reader chooses is still there next launch, through the control rather than the store.
    @Test func theChosenPolicySurvivesALaunch() throws {
        let suite = try #require(UserDefaults(suiteName: "ai.xdict.tests.hover.\(UUID().uuidString)"))
        var chosen = HoverPolicy.shipped
        chosen.modifier = .command
        try control(suite).setPolicy(chosen)
        #expect(try control(suite).policy.modifier == .command)
    }
}

/// **The wire to Settings** (XiaolaiDict's `CaptureHealthWiringTests`, moved by name): a stuck lane reported by the
/// watcher reaches the observed state Settings reads, as the consumer's notice. Red if the control stops listening.
@MainActor
struct CaptureHealthWiringTests {
    @Test func aStuckCaptureReachesTheObservedState() throws {
        let hover = try control()
        #expect(hover.notice == nil)
        hover.watcher.onCaptureHealth?(.stuck(for: .seconds(9)))
        #expect(hover.notice == .captureStuck)
        hover.watcher.onCaptureHealth?(.answering)
        #expect(hover.notice == nil)
    }
}

/// The control's own rules (new in XDict, plan-capture WI-3).
@MainActor
struct HoverControlTests {
    /// **The scripts are the enabled dictionaries', read at decision time**, never stored: what the gate's policy holds
    /// follows the provider, and the stored policy carries none.
    @Test func theScriptsComeFromTheProviderAtDecisionTime() throws {
        final class Box { var scripts: Set<CaptureScript>? = [.latin] }
        let box = Box()
        let hover = try control(scripts: { box.scripts })
        #expect(hover.effectivePolicy.allowedScripts == [.latin])
        box.scripts = [.han]
        #expect(hover.effectivePolicy.allowedScripts == [.han])
        #expect(hover.policy.allowedScripts == nil)
    }

    /// **Hover is on for a reader who never chose, and remembers one who did**, through the injected suite.
    @Test func hoverIsOnUntilTheReaderTurnsItOff() throws {
        let suite = try #require(UserDefaults(suiteName: "ai.xdict.tests.hover.\(UUID().uuidString)"))
        #expect(try control(suite).isEnabled)
        try control(suite).isEnabled = false
        #expect(try !control(suite).isEnabled)
    }

    /// **Hover off starts nothing**: launching with the reader's hover turned off installs no watcher. Red if
    /// `startAtLaunch` ignores the setting.
    @Test func hoverOffStartsNoWatcher() throws {
        let hover = try control()
        hover.isEnabled = false
        hover.startAtLaunch(.reader)
        #expect(!hover.isWatching, "a hover the reader turned off was started")
        #expect(!hover.watcher.isWatching)
    }

    /// **A driven run starts no hover**, with hover on: a key the instrument holds must not open a lookup it did not ask
    /// for. Red if `startAtLaunch` ignores the launch.
    @Test func anInstrumentLaunchStartsNoWatcher() throws {
        let hover = try control()
        #expect(hover.isEnabled)
        hover.startAtLaunch(.instrument)
        #expect(!hover.isWatching, "a driven run started hover")
        #expect(!hover.watcher.isWatching)
    }

    /// **The capture targets get the tokens' distances**, valid by construction (ADR-0014 d.11).
    @Test func theTolerancesAreTheTokens() {
        #expect(CaptureTolerances.hit.horizontal > 0 && CaptureTolerances.hit.vertical > 0)
        #expect(CaptureTolerances.hit.horizontal >= CaptureTolerances.hit.vertical, "across is the looser of the two")
        #expect(CaptureTolerances.restDrift > 0)
    }
}

/// **Screen Recording, from Settings** (plan-capture WI-4; XDict ADR-0014 decision 7): the row is the only thing that asks,
/// and before it nothing that could prompt is called — not at launch, not by Settings showing the row, not by a hover.
@MainActor
struct ScreenRecordingRowTests {
    /// **Showing the row touches nothing** before it was used: it says "not set up" without asking the system. Red if the
    /// row's refresh probes first.
    @Test func showingTheRowAsksNothingBeforeItIsUsed() async throws {
        let screen = CountedScreen()
        let hover = try control(screen: screen)
        await hover.refreshScreenRecording()
        #expect(hover.screenRecording == .notSetUp)
        #expect(screen.probes == 0 && screen.requests == 0)
    }

    /// **Starting hover at launch touches nothing either.**
    @Test func launchingHoverAsksNothing() throws {
        let screen = CountedScreen()
        let hover = try control(screen: screen)
        hover.startAtLaunch(.reader)
        hover.watcher.stop()
        #expect(screen.probes == 0 && screen.requests == 0)
    }

    /// **Using the row asks once and says what macOS answered**; after it, the row may check again on its own.
    @Test func usingTheRowAsksAndSaysTheAnswer() async throws {
        let screen = CountedScreen(answer: .declined)
        let hover = try control(screen: screen)
        await hover.setUpScreenRecording()
        #expect(screen.requests == 1)
        #expect(hover.screenRecording == .notAllowed)
        await hover.refreshScreenRecording()
        #expect(screen.requests == 1, "checking again asked again")
        #expect(screen.probes == 2)
    }

    /// A grant macOS already reports needs no row: the row says allowed without asking.
    @Test func aStandingGrantIsShownWithoutAsking() async throws {
        let screen = CountedScreen(answer: .granted, standing: true)
        let hover = try control(screen: screen)
        await hover.refreshScreenRecording()
        #expect(hover.screenRecording == .allowed)
        #expect(screen.requests == 0)
    }

    /// **The notice reaches Settings** when a hover needed the pixels, and goes once the grant is there.
    @Test func aScreenRecordingNoticeReachesTheObservedState() async throws {
        let hover = try control(screen: CountedScreen(answer: .granted))
        #expect(hover.notice == nil)
        hover.watcher.onNotice?(.screenRecordingNeeded)
        #expect(hover.notice == .screenRecordingNeeded)
        await hover.setUpScreenRecording()
        #expect(hover.notice == nil, "the notice stayed after the grant")
    }

    /// **The reader starts its pending contexts in the session's book**, so the consumer finds a presented term's handle.
    @Test func theReaderStartsContextsInTheSessionsBook() throws {
        let hover = try control()
        let reader = try #require(hover.watcher.reader as? HoverReader)
        #expect(reader.contexts === hover.contextSession.pending)
    }

    /// **The recogniser gets the tokens' strip, tiling and frame distances** (ADR-0014 d.11), valid by construction.
    @Test func theRecognitionMetricsAreTheTokens() {
        let metrics = CaptureTolerances.metrics
        #expect(metrics.hit == CaptureTolerances.hit)
        #expect(metrics.strip == StripMetrics(initialHeight: Tokens.Capture.stripStart, growthStep: Tokens.Capture.stripStep,
                                              maximumHeight: Tokens.Capture.stripMost))
        #expect(metrics.tiling == TilingMetrics(edgeSlack: Tokens.Capture.tileEdgeSlack, holeSlack: Tokens.Capture.tileHoleSlack))
        #expect(metrics.frameDrift == Tokens.Capture.frameDrift)
        #expect(metrics.strip.initialHeight < metrics.strip.maximumHeight, "a strip that cannot grow")
    }
}

/// **Which launch this is, decided once from the arguments** (plan-capture WI-3): a typed value, so the decision cannot be
/// negated by a stray `!`, tested both ways.
struct HoverLaunchTests {
    static let flags = ["--lookup-window", "--anywhere", "--measure"]

    @Test func aLaunchWithoutAnInstrumentFlagIsTheReaders() {
        #expect(HoverLaunch.of(arguments: [], instrumentFlags: Self.flags) == .reader)
        #expect(HoverLaunch.of(arguments: ["--anywhere-not", "-NSDocumentRevisionsDebugMode", "YES"],
                               instrumentFlags: Self.flags) == .reader, "a flag matched by prefix")
    }

    @Test func anyInstrumentFlagMakesItAnInstrumentRun() {
        for flag in Self.flags {
            #expect(HoverLaunch.of(arguments: ["--other", flag], instrumentFlags: Self.flags) == .instrument, "\(flag)")
        }
    }
}

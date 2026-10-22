import CoreGraphics
import Foundation
import Observation
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
    func target(
        at point: CGPoint, windows: @escaping @Sendable () -> [ListedWindow], refusesOwner: @escaping @Sendable (pid_t) -> Bool
    ) async -> PointerWordReader.TargetOutcome {
        .none(.nothingAtPointer)
    }
    func readUnlessRefused(
        at point: CGPoint, in target: PointerWordReader.Target, refuses: @escaping @Sendable (HostReading) -> Bool,
        budget: Duration
    ) async -> PointerWordReader.GatedOutcome {
        reads += 1
        return .read(.miss(.noText(app: "", role: nil)))
    }
    func ownView(at point: CGPoint) -> OwnView { .controls }
    func ownTarget(at point: CGPoint) async -> PointerWordReader.OwnTargetOutcome { .none(.nothingAtPointer) }
    func readOwnUnlessRefused(
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
    scripts: @escaping @MainActor () -> Set<CaptureScript>? = { nil },
    start: @escaping @MainActor (HoverWatcher) -> Bool = HoverControl.systemStart,
    warmUp: @escaping @MainActor () -> Void = {},
    keepWarm: RecognitionKeepWarm = RecognitionKeepWarm(warm: {}, sleep: { _ in await Task.yield() })
) throws -> HoverControl {
    let suite = try defaults ?? #require(UserDefaults(suiteName: "ai.xdict.tests.hover.\(UUID().uuidString)"))
    return HoverControl(defaults: suite, requests: CaptureRequests(), screen: screen.access, source: SilentPointerWords(),
                        scripts: scripts, startWatcher: start, warmUpRecognition: warmUp, keepWarm: keepWarm)
}

/// **The recogniser is warmed once, when hover starts in a reader's launch** (Vision's first recognition after idle took
/// 25 s on the build Mac, 2026-10-19, system-wide; later first calls 78–80 ms): never in a driven run, never with hover
/// off, never for a start that failed, never twice in one launch — and it asks nothing of Screen Recording.
@MainActor
struct RecognitionWarmUpTests {
    @MainActor
    final class Count {
        var value = 0
        func warm() { value += 1 }
    }

    @Test func aReadersLaunchWarmsOnceAndAsksNothingOfTheScreen() throws {
        let warmed = Count(), screen = CountedScreen()
        let hover = try control(screen: screen, start: ScriptedStarts([true]).start, warmUp: warmed.warm)
        hover.startAtLaunch(.reader)
        #expect(warmed.value == 1)
        #expect(screen.probes == 0 && screen.requests == 0, "the warm-up touched Screen Recording")
        // Off and on again in the same launch: the watcher restarts, the recogniser is not warmed again.
        hover.setEnabled(false)
        hover.setEnabled(true)
        #expect(warmed.value == 1, "warmed \(warmed.value) times in one launch")
    }

    @Test func aDrivenRunNeverWarms() throws {
        let warmed = Count()
        let hover = try control(start: ScriptedStarts([true]).start, warmUp: warmed.warm)
        hover.startAtLaunch(.instrument)
        hover.setEnabled(false)
        hover.setEnabled(true)
        #expect(warmed.value == 0)
    }

    @Test func hoverOffWarmsOnlyOnceTurnedOn() throws {
        let warmed = Count()
        let hover = try control(start: ScriptedStarts([true]).start, warmUp: warmed.warm)
        hover.isEnabled = false
        hover.startAtLaunch(.reader)
        #expect(warmed.value == 0, "warmed with hover off")
        hover.setEnabled(true)
        #expect(warmed.value == 1)
    }

    @Test func aFailedStartDoesNotWarm() throws {
        let warmed = Count()
        let hover = try control(start: ScriptedStarts([false]).start, warmUp: warmed.warm)
        hover.startAtLaunch(.reader)
        #expect(warmed.value == 0)
    }

    /// **Vision is kept warm exactly while the watcher runs in a reader's launch** (2026-10-19: its models are dropped
    /// after minutes idle and took 24 s to load again): started with the watcher, stopped with hover off, started again
    /// on, never in a driven run, never for a start that failed. Red if the keep-warm is not wired, or outlives hover.
    @Test func visionIsKeptWarmOnlyWhileTheWatcherRuns() throws {
        let reader = try control(start: ScriptedStarts([true]).start)
        #expect(!reader.keepWarm.isRunning)
        reader.startAtLaunch(.reader)
        #expect(reader.keepWarm.isRunning)
        reader.setEnabled(false)
        #expect(!reader.keepWarm.isRunning, "kept warm with hover off")
        reader.setEnabled(true)
        #expect(reader.keepWarm.isRunning)
        reader.setEnabled(false)

        let driven = try control(start: ScriptedStarts([true]).start)
        driven.startAtLaunch(.instrument)
        driven.setEnabled(true)
        #expect(!driven.keepWarm.isRunning, "kept warm in a driven run")

        let failed = try control(start: ScriptedStarts([false]).start)
        failed.startAtLaunch(.reader)
        #expect(!failed.keepWarm.isRunning, "kept warm for a watcher that did not start")
    }
}

/// **The keep-warm's own rule**: one warm-up per interval in which Vision answered nothing, none where it answered, and
/// none after `stop`. The interval's sleep is the test's, released a tick at a time.
@MainActor
struct RecognitionKeepWarmTests {
    /// A sleep that returns when the test says, one tick at a time.
    final class Ticks: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var pending: Int { lock.withLock { waiting.count } }
        func sleep(_: Duration) async { await withCheckedContinuation { c in lock.withLock { waiting.append(c) } } }
        func tick() { lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }?.resume() }
    }

    private func settle(until condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    @Test func aTickWarmsOnlyWhereVisionWasIdle() async {
        @MainActor final class Vision {
            var warmed = 0
            var idle = true
        }
        let ticks = Ticks()
        let vision = Vision()
        let keepWarm = RecognitionKeepWarm(interval: .seconds(120), warm: { vision.warmed += 1 },
                                           idle: { _ in vision.idle }, sleep: { await ticks.sleep($0) })
        keepWarm.start()
        await settle { ticks.pending == 1 }
        ticks.tick()
        await settle { vision.warmed == 1 && ticks.pending == 1 }
        #expect(vision.warmed == 1, "an idle interval was not warmed")
        vision.idle = false
        ticks.tick()
        await settle { ticks.pending == 1 }
        #expect(vision.warmed == 1, "warmed although Vision had answered within the interval")
        vision.idle = true
        keepWarm.stop()
        ticks.tick()
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(vision.warmed == 1, "warmed after stop")
        #expect(!keepWarm.isRunning)
    }
}

/// Watcher starts answered in order (the last answer repeating), counted; the system's monitors never touched.
@MainActor
final class ScriptedStarts {
    private var answers: [Bool]
    private(set) var calls = 0
    init(_ answers: [Bool]) { self.answers = answers }
    func start(_ watcher: HoverWatcher) -> Bool {
        calls += 1
        return answers.count > 1 ? answers.removeFirst() : answers.first ?? false
    }
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

    /// **The key and gesture the reader actually has, for the setup board's line** (plan-setup-v2 WI-4): read-only
    /// accessors over the one stored policy, so the board cannot say "hold ⌥" to a reader who taps ⌥⌥.
    @Test func theGestureAndKeyFollowTheReadersPolicy() throws {
        let hover = try control()
        #expect(hover.isDoubleTap == (hover.policy.gesture == .doubleTap))
        #expect(hover.keySymbol == hover.policy.modifier.symbol)
        var changed = hover.policy
        changed.gesture = .doubleTap
        hover.setPolicy(changed)
        #expect(hover.isDoubleTap)
        #expect(hover.keySymbol == hover.policy.modifier.symbol, "the key is the key; the verb says how it is used")
        #expect(hover.isOn == hover.isEnabled, "reading the gesture changes nothing about whether hover runs")
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

    /// **The menu and the switch show the reader's setting, not whether this run watches** (UI tour, 2026-10-19: in a
    /// driven run the menu said "Hover Is Off in Settings" with hover on in Settings, and Pause Hover could not be
    /// reached). The pause group follows the setting and the control's one pause. Red if either reads the watcher.
    @Test func aDrivenRunShowsTheReadersSettingNotTheWatcher() throws {
        let hover = try control()
        let now = Date.now
        hover.startAtLaunch(.instrument)
        #expect(!hover.watcher.isWatching)
        #expect(hover.isOn, "a driven run said hover is off with the reader's setting on")
        #expect(HoverPauseMenu.entries(for: hover, now: now) == [.pause])
        hover.pause(for: .seconds(900))
        let paused = HoverPauseMenu.entries(for: hover, now: now)
        #expect(paused.count == 2 && paused.last == .resume, "the menu offered \(paused)")
        hover.resume()
        hover.setEnabled(false)
        #expect(!hover.isOn)
        #expect(HoverPauseMenu.entries(for: hover, now: now) == [.hoverIsOff])
    }

    /// **Turning hover on in a driven run starts nothing either**: the switch stores the setting, and only a reader's
    /// launch starts the watcher. Red if `setEnabled` starts it whatever the launch.
    @Test func turningHoverOnInADrivenRunStartsNoWatcher() throws {
        let hover = try control()
        defer { hover.watcher.stop() }
        hover.startAtLaunch(.instrument)
        hover.setEnabled(false)
        hover.setEnabled(true)
        #expect(hover.isEnabled && hover.isOn)
        #expect(!hover.watcher.isWatching, "a driven run's switch started hover")
    }

    /// **A reader's launch still starts it, and the switch still stops it**: what the setting says is what runs.
    @Test func aReadersLaunchWatchesWhatTheSettingSays() throws {
        let hover = try control()
        defer { hover.watcher.stop() }
        hover.startAtLaunch(.reader)
        #expect(hover.isOn && hover.watcher.isWatching)
        hover.setEnabled(false)
        #expect(!hover.isOn && !hover.watcher.isWatching)
        hover.setEnabled(true)
        #expect(hover.isOn && hover.watcher.isWatching)
    }

    /// **A start that failed says off**, in the switch (`isOn`) and in the menu, though the setting stays on: a hover that
    /// is not running is not shown as running. Red if `isOn` reads the setting alone, or the failure is not remembered.
    @Test func aFailedStartShowsOffInTheSwitchAndTheMenu() throws {
        let starts = ScriptedStarts([false])
        let hover = try control(start: starts.start)
        hover.startAtLaunch(.reader)
        #expect(starts.calls == 1)
        #expect(hover.isEnabled, "a failed start changed the reader's setting")
        #expect(!hover.isOn, "a hover whose start failed was shown on")
        #expect(HoverPauseMenu.entries(for: hover, now: .now) == [.hoverIsOff])
    }

    /// **Turning the switch on again tries again**, and a start that succeeds clears the failure.
    @Test func turningTheSwitchOnRetriesAFailedStart() throws {
        let starts = ScriptedStarts([false, false, true])
        let hover = try control(start: starts.start)
        hover.startAtLaunch(.reader)
        hover.setEnabled(true)
        #expect(starts.calls == 2, "the switch did not try again")
        #expect(!hover.isOn)
        hover.setEnabled(true)
        #expect(starts.calls == 3)
        #expect(hover.isOn, "a start that succeeded left hover shown off")
        #expect(HoverPauseMenu.entries(for: hover, now: .now) == [.pause])
    }

    /// **A driven run never asks the watcher to start**, at launch or from the switch.
    @Test func aDrivenRunNeverAsksTheWatcherToStart() throws {
        let starts = ScriptedStarts([true])
        let hover = try control(start: starts.start)
        hover.startAtLaunch(.instrument)
        hover.setEnabled(false)
        hover.setEnabled(true)
        #expect(starts.calls == 0, "a driven run asked the watcher to start")
        #expect(hover.isOn)
    }

    /// **The setting is observed**, so the menu and the switch redraw when it changes, in a run that watches nothing.
    @Test func turningHoverOffIsObserved() throws {
        let hover = try control()
        hover.startAtLaunch(.instrument)
        /// `@unchecked`: its one value is read and written under `lock`.
        final class Fired: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            var value: Bool { lock.withLock { fired } }
            func fire() { lock.withLock { fired = true } }
        }
        let fired = Fired()
        withObservationTracking { _ = hover.isOn } onChange: { fired.fire() }
        hover.setEnabled(false)
        #expect(fired.value, "turning hover off was not observed")
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

    /// **A notice the watcher tells is shown by the pointer, at most once a while for each kind** (owner's report,
    /// 2026-10-19: a miss showed nothing). A reader double-tapping blank space is told once, not at every tap; another
    /// kind is told at once; the same kind again after the interval. Red while nothing reached the consumer.
    @Test func aBriefNoticeIsShownAtMostOnceAWhile() throws {
        final class Clock { var now = ContinuousClock.now }
        let clock = Clock()
        let suite = try #require(UserDefaults(suiteName: "ai.xdict.tests.hover.\(UUID().uuidString)"))
        let hover = HoverControl(defaults: suite, requests: CaptureRequests(), screen: CountedScreen().access,
                                 source: SilentPointerWords(), now: { clock.now })
        var shown: [CaptureNotice] = []
        hover.showBriefNotice = { shown.append($0) }
        hover.watcher.onNotice?(.nothingUnderPointer)
        hover.watcher.onNotice?(.nothingUnderPointer)
        hover.watcher.onNotice?(.screenRecordingNeeded)
        #expect(shown == [.nothingUnderPointer, .screenRecordingNeeded])
        clock.now += HoverNoticeThrottle.interval
        hover.watcher.onNotice?(.nothingUnderPointer)
        #expect(shown == [.nothingUnderPointer, .screenRecordingNeeded, .nothingUnderPointer])
        #expect(hover.notice == .screenRecordingNeeded, "the Settings notice stopped following the watcher")
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

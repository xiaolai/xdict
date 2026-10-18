import AppKit
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **The watcher, driven by event sequences** (XiaolaiDict's `HoverWatcherSequenceTests`, moved by name in plan-capture
/// WI-3, ADR-0014 decision 10). Each test drives the real watcher with scripted events, a pointer, a hand-fired timer and
/// a reader whose reads end on command; what it hands over goes through the app's one `CaptureRequests` to a sink, as a
/// `CapturedTerm`, rather than to XiaolaiDict's panel protocol.
@MainActor
struct HoverWatcherSequenceTests {
    @MainActor
    final class Rig {
        let events = ScriptedHoverEvents()
        let pointer = ScriptedPointer()
        let timer = ManualSchedule()
        let reader = ScriptedHoverReader()
        let requests = CaptureRequests()
        let sink = RecordingSink()
        let watcher: HoverWatcher
        /// The monotonic clock the watcher reads, which the test moves.
        let clock = TestClock()

        @MainActor
        final class TestClock {
            var now = ContinuousClock.now
        }

        init(gesture: HoverGesture = .hold) {
            var policy = HoverPolicy.shipped
            policy.gesture = gesture
            let pointer = pointer, timer = timer, clock = clock
            watcher = HoverWatcher(
                policy: { policy }, requests: requests, restTolerance: HoverFixtures.rest,
                primaryHeight: { 1_000 }, events: events, pointer: { pointer.read() },
                schedule: { timer.schedule($0, $1) }, now: { clock.now }, reader: reader)
            watcher.sink = sink
            watcher.start()
        }

        /// The pointer arrives with ⌥ down and the settle timer fires; waits for the read to start.
        func rest(at point: UpPoint = UpPoint(x: 100, y: 100)) async {
            let before = reader.asks.count
            pointer.at = point
            pointer.held = [.option]
            events.emit(.pointerMoved)
            timer.fire()
            await asks(before + 1)
        }

        func asks(_ count: Int) async {
            await HoverFixtures.settle { self.reader.asks.count >= count }
        }

        func drain() async { await HoverFixtures.drain() }
    }

    // MARK: - The gesture rule's wire

    /// **The watcher asks the gesture rule, with the reader's own gesture and key.** Under double-tap the third press is a
    /// request, asked at once; under hold the same presses are not a tap. Red if the watcher stops passing `.modifiers`
    /// events to the session.
    @Test func aDoubleTapIsAskedAtOnceUnderTheTapGestureOnly() async {
        let tapping = Rig(gesture: .doubleTap)
        tapping.events.doubleTap(from: 10)
        await tapping.asks(1)
        #expect(tapping.timer.armed > 0, "the settle timer was not what asked")
        #expect(tapping.reader.asks.map(\.tapped) == [true], "the tap was not served at once")

        let holding = Rig(gesture: .hold)
        holding.events.doubleTap(from: 10)
        await holding.drain()
        #expect(!holding.reader.asks.contains { $0.tapped }, "a tap under the hold gesture")
    }

    /// **The event's own time, not the clock's.** Three presses delivered back to back whose timestamps are a second
    /// apart are not a tap. Red if the watcher dates presses on arrival.
    @Test func theEventsOwnTimeDecidesTheTapWindow() async {
        let rig = Rig(gesture: .doubleTap)
        rig.events.emit(.modifiers([.option], at: 10, location: nil))
        rig.events.emit(.modifiers([], at: 10.5, location: nil))
        rig.events.emit(.modifiers([.option], at: 11.2, location: nil))
        await rig.drain()
        #expect(rig.reader.asks.isEmpty)
    }

    /// **The event's own flags, not the current ones.** The pointer source says nothing is held; the events say ⌥ went
    /// down, up, down — and that is a tap.
    @Test func theEventsOwnFlagsDecideThePress() async {
        let rig = Rig(gesture: .doubleTap)
        rig.pointer.held = []
        rig.events.doubleTap(from: 20)
        await rig.asks(1)
        #expect(rig.reader.asks.count == 1)
    }

    /// **Other input cancels a half-made pair.** ⌥←, ⌥← is two presses of ⌥ inside the window.
    @Test func otherInputBetweenPressesIsNotATap() async {
        let rig = Rig(gesture: .doubleTap)
        rig.events.emit(.modifiers([.option], at: 30, location: nil))
        rig.events.emit(.modifiers([], at: 30.05, location: nil))
        rig.events.emit(.otherInput)
        rig.events.emit(.modifiers([.option], at: 30.2, location: nil))
        await rig.drain()
        #expect(rig.reader.asks.isEmpty)
    }

    /// Keys, clicks and scrolls all reach the rule as other input, and are all watched.
    @Test func everyKindOfOtherInputIsWatchedAndMapped() {
        for (type, mask) in [(NSEvent.EventType.keyDown, NSEvent.EventTypeMask.keyDown),
                             (.leftMouseDown, .leftMouseDown), (.scrollWheel, .scrollWheel)] {
            #expect(SystemHoverEvents.event(type: type, flags: [], timestamp: 0) == .otherInput)
            #expect(SystemHoverEvents.watched.contains(mask), "\(type) is not watched")
        }
        #expect(SystemHoverEvents.event(type: .flagsChanged, flags: [.option, .capsLock], timestamp: 7)
                == .modifiers([.option], at: 7, location: nil))
    }

    /// **A tap is served at once, at the point it was made, and never again.** A tap that was stored and spent by a later
    /// read could be spent at a word the reader did not point at.
    @Test func aTapIsServedAtItsOwnPointAndNotSpentLater() async {
        let rig = Rig(gesture: .doubleTap)
        rig.pointer.at = UpPoint(x: 300, y: 900)
        rig.events.doubleTap(from: 40)
        await rig.asks(1)
        #expect(rig.reader.asks.first?.point == CGPoint(x: 300, y: 100))
        rig.reader.answer(.quiet(.samePlace))
        await HoverFixtures.settle { rig.reader.pendingReads == 0 }
        rig.pointer.at = UpPoint(x: 700, y: 500)
        rig.events.emit(.pointerMoved)
        rig.timer.fire()
        await rig.drain()
        rig.reader.answer(.quiet(.notTapped))
        await rig.drain()
        #expect(!rig.reader.asks.dropFirst().contains { $0.tapped }, "a tap was spent at another word")
    }

    /// **Stopping resets the rule.** A press before a stop and a press after a start are not a pair.
    @Test func stoppingResetsTheRule() async {
        let rig = Rig(gesture: .doubleTap)
        rig.events.emit(.modifiers([.option], at: 50, location: nil))
        rig.events.emit(.modifiers([], at: 50.05, location: nil))
        rig.watcher.stop()
        rig.watcher.start()
        rig.events.emit(.modifiers([.option], at: 50.1, location: nil))
        await rig.drain()
        #expect(rig.reader.asks.isEmpty)
    }

    /// A partial install leaves hover off rather than on with a gesture missing.
    @Test func aFailedInstallLeavesHoverOff() {
        let rig = Rig()
        rig.watcher.stop()
        rig.events.installs = false
        rig.watcher.start()
        #expect(!rig.watcher.isWatching)
    }

    // MARK: - The lifecycle

    /// **The race, end to end.** A hover is asked; while it reads, the reader presses the shortcut, which claims
    /// presentation; the hover's late word is not delivered and not remembered, and its request ends cancelled.
    @Test func aLateHoverDoesNotReplaceALookupMadeMeanwhile() async {
        let rig = Rig()
        await rig.rest()
        let shortcut = rig.requests.beginPresenting(.selection)
        rig.reader.answerWord()
        await rig.drain()
        #expect(rig.sink.all.isEmpty, "the late hover replaced the shortcut's lookup")
        #expect(rig.reader.remembered.isEmpty, "a word nobody was shown was remembered")
        #expect(rig.requests.isCurrent(shortcut))
        #expect(rig.requests.terminal(of: rig.reader.asks[0].request)?.outcome == .cancelled)
    }

    /// **The word is dated from the ask**, not from when it arrived: the pointer sample handed over carries the moment
    /// the gesture was accepted. Red if delivery dates the request on arrival.
    @Test func aDeliveredWordIsDatedFromTheAsk() async {
        let rig = Rig()
        let asked = rig.clock.now
        await rig.rest()
        rig.clock.now = asked + .seconds(4)
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { !rig.sink.all.isEmpty }
        #expect(rig.sink.all.first?.term.pointer?.at == asked)
    }

    /// **The number is taken when the read is asked**, so a shortcut pressed before the read's task first runs is
    /// numbered after the hover, and wins. Red if the number is taken inside the task.
    @Test func aHoverAskedBeforeAShortcutIsNumberedBeforeIt() async {
        let rig = Rig()
        rig.pointer.held = [.option]
        rig.events.emit(.pointerMoved)
        rig.timer.fire()
        let shortcut = rig.requests.beginPresenting(.selection)
        await rig.asks(1)
        #expect((rig.reader.asks.first?.request.number ?? .max) < shortcut.number,
                "the older hover was numbered after the shortcut")
    }

    /// **Letting go of the key ends the hover at once**, so a quick release and re-press can look the same word up again.
    /// Red if only a read observing the key up clears the suppression.
    @Test func releasingTheKeyEndsTheHover() {
        let rig = Rig()
        rig.events.emit(.modifiers([.option], at: 1, location: nil))
        #expect(rig.reader.hoversEnded == 0)
        rig.events.emit(.modifiers([], at: 1.1, location: nil))
        #expect(rig.reader.hoversEnded == 1)
    }

    /// The ordinary case still works: a word that stands is delivered, as a pointer-gesture term, and then remembered.
    @Test func aWordThatStandsIsDeliveredThenRemembered() async {
        let rig = Rig()
        await rig.rest()
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { !rig.sink.all.isEmpty }
        #expect(rig.sink.terms == ["tide"])
        #expect(rig.sink.all.first?.term.trigger == .pointerGesture)
        #expect(rig.sink.all.first?.request == rig.reader.asks.first?.request)
        #expect(rig.reader.remembered.count == 1)
    }

    /// **The word's box and the pointer reach the consumer in the space the term speaks** (changed on the way: XiaolaiDict
    /// flipped the box for its panel; XDict hands the measured box over y down, as `CapturedTerm` holds it, and the
    /// pointer flipped once about the primary display's height — 1,000 here — beside it). A word read with no box hands
    /// none over.
    @Test func theWordsBoxIsDeliveredAsReadBesideThePointerFlippedOnce() async {
        let rig = Rig()
        await rig.rest()
        let read = ReadBounds(rect: DownRect(x: 90, y: 890, width: 40, height: 20), quality: .exact)
        rig.reader.answerWord("tide", bounds: read)
        await HoverFixtures.settle { !rig.sink.all.isEmpty }
        #expect(rig.sink.all.map(\.term.box) == [.measured(read)])
        #expect(rig.sink.all.first?.term.pointer?.point == DownPoint(x: 100, y: 900))
    }

    @Test func aWordReadWithNoBoxDeliversNone() async {
        let rig = Rig()
        await rig.rest()
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { !rig.sink.all.isEmpty }
        #expect(rig.sink.all.map(\.term.box) == [.absent])
    }

    /// **A word whose presentation never drew is forgotten** (XiaolaiDict audit round 3, #38): remembered on delivery, so a
    /// failed opening left the reader unable to ask for that word again by resting on it. The consumer's terminal
    /// acknowledgement — here, not shown — is what forgets it.
    @Test func aWordWhosePanelNeverDrewIsForgotten() async throws {
        let rig = Rig()
        await rig.rest()
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { !rig.sink.all.isEmpty }
        let delivery = try #require(rig.sink.all.first)
        rig.requests.acknowledge(delivery.request, generation: delivery.generation, .notShown)
        await HoverFixtures.settle { !rig.reader.forgotten.isEmpty }
        #expect(rig.reader.forgotten == rig.reader.remembered, "a word nobody saw stayed remembered")
    }

    /// And one that drew stays remembered.
    @Test func aWordWhosePanelDrewStaysRemembered() async throws {
        let rig = Rig()
        await rig.rest()
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { !rig.sink.all.isEmpty }
        let delivery = try #require(rig.sink.all.first)
        rig.requests.acknowledge(delivery.request, generation: delivery.generation, .shown)
        await rig.drain()
        #expect(rig.reader.forgotten.isEmpty)
    }

    /// **Leaving the word drops it**, nothing is remembered, and its request ends rather than staying open for ever.
    @Test func aWordReadAfterThePointerLeftIsDropped() async {
        let rig = Rig()
        await rig.rest()
        rig.pointer.at = UpPoint(x: 400, y: 100)
        rig.events.emit(.pointerMoved)
        rig.reader.answerWord()
        await rig.drain()
        #expect(rig.sink.all.isEmpty)
        #expect(rig.reader.remembered.isEmpty)
        #expect(rig.requests.terminal(of: rig.reader.asks[0].request)?.outcome == .cancelled, "the dropped request stayed open")
    }

    /// **Stopping ends the hover** (XiaolaiDict's `HoverWatcherRoundTwoTests`), so a key let go while stopped does not
    /// leave the word suppressed.
    @Test func stoppingEndsTheHover() {
        let rig = Rig()
        rig.watcher.stop()
        #expect(rig.reader.hoversEnded >= 1)
    }

    /// **A read that found nothing ends its request** (new in XDict: every request ends exactly once, ADR-0014 d.4).
    @Test func aReadThatFoundNothingEndsItsRequest() async {
        let rig = Rig()
        await rig.rest()
        rig.reader.answer(.nothing(.miss(.noText(app: "TextEdit", role: nil))))
        await rig.drain()
        #expect(rig.requests.terminal(of: rig.reader.asks[0].request)?.outcome == .cancelled)
    }
}

/// What only the watcher decides (XiaolaiDict's `HoverWatcherTests`, moved by name): read the modifiers, decide the
/// pointer is at rest, and hand the reader a point in the space it works in.
struct HoverWatcherTests {
    @Test func holdingOptionIsReportedAsOption() {
        #expect(HoverWatcher.modifiers(of: [.option]) == [.option])
    }

    @Test func everyModifierHeldIsReported() {
        #expect(HoverWatcher.modifiers(of: [.option, .control, .command, .shift]) == [.option, .control, .command, .shift])
    }

    @Test func holdingNothingIsAnEmptySet() {
        #expect(HoverWatcher.modifiers(of: []).isEmpty)
    }

    /// Caps lock and the function key are not hover modifiers.
    @Test func keysThatAreNotHoverModifiersAreIgnored() {
        #expect(HoverWatcher.modifiers(of: [.capsLock, .function, .numericPad]).isEmpty)
        #expect(HoverWatcher.modifiers(of: [.capsLock, .option]) == [.option])
    }

    @Test func aPointerThatTwitchesIsStillAtRest() {
        #expect(!HoverSession.hasMoved(from: UpPoint(x: 100, y: 100), to: UpPoint(x: 101, y: 99), tolerance: HoverFixtures.rest))
    }

    @Test func aPointerThatCrossesTheToleranceHasMoved() {
        #expect(HoverSession.hasMoved(from: UpPoint(x: 100, y: 100), to: UpPoint(x: 140, y: 100), tolerance: HoverFixtures.rest))
        #expect(HoverSession.hasMoved(from: UpPoint(x: 100, y: 100), to: UpPoint(x: 100, y: 140), tolerance: HoverFixtures.rest))
    }

    @Test func aPointerThatHasNotMovedAtAllIsAtRest() {
        #expect(!HoverSession.hasMoved(from: UpPoint(x: 100, y: 100), to: UpPoint(x: 100, y: 100), tolerance: HoverFixtures.rest))
    }

    @Test func diagonalDriftCountsAsMovement() {
        #expect(HoverSession.hasMoved(from: UpPoint(x: 100, y: 100), to: UpPoint(x: 103, y: 103), tolerance: HoverFixtures.rest))
    }

    @Test func thePrimaryIsTheDisplayAtTheGlobalOrigin() {
        let secondary = UpRect(x: -1920, y: 0, width: 1920, height: 1080)
        let primary = UpRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(HoverWatcher.primaryHeight(among: [secondary, primary]) == 1440)
    }

    @Test func withNoDisplayAtTheOriginTheFirstOneIsUsed() {
        #expect(HoverWatcher.primaryHeight(among: [UpRect(x: 100, y: 100, width: 1920, height: 1080)]) == 1080)
    }

    @Test func withNoDisplaysAtAllThereIsNoHeight() {
        #expect(HoverWatcher.primaryHeight(among: []) == nil)
    }

    /// **The watcher hands its pause to the reader**, and the refusal is decided before any Accessibility call.
    @Test @MainActor func aPausedXDictRefusesBeforeItReadsAnything() async {
        var paused = HoverPause()
        paused.pause(for: .seconds(600), from: .now)
        let screen = ScriptedPointerWords()
        let watcher = HoverWatcher(policy: { .shipped }, pause: { paused }, requests: CaptureRequests(), source: screen,
                                   restTolerance: HoverFixtures.rest)
        let outcome = await watcher.reader.read(
            at: .zero, modifiersHeld: [HoverPolicy.shipped.modifier], tappedTwice: false, pointerStillFor: .seconds(10),
            begin: { CaptureRequest(number: 0, trigger: .pointerGesture) })
        guard case .quiet(.paused) = outcome else {
            Issue.record("a paused XDict answered \(outcome) — the pause never reached the reader")
            return
        }
        #expect(screen.reads == 0)
    }

    /// The pointer arrives y up and the reader works y down.
    @Test func aPointerNearTheTopOfTheScreenReadsNearZeroGoingDown() throws {
        let height = try #require(HoverWatcher.primaryHeight(among: [UpRect(x: 0, y: 0, width: 2560, height: 1440)]))
        #expect(UpPoint(x: 800, y: 1400).flipped(aboutPrimaryHeight: height) == DownPoint(x: 800, y: 40))
    }
}

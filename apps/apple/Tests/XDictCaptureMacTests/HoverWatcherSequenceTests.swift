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

    /// **A hover inside the presented popover replaces its presentation** (owner, 2026-10-19: hover works in XDict's own
    /// windows, the popover included; the key held is what asks, so the popover cannot ask by itself). The second word is
    /// numbered after the first, claims presentation, and is delivered under its own generation; the first's `shown`
    /// stands, and both stay remembered.
    @Test func aHoverInsideThePresentedPopoverReplacesItsPresentation() async throws {
        let rig = Rig()
        await rig.rest(at: UpPoint(x: 100, y: 100))
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { rig.sink.all.count == 1 }
        let first = try #require(rig.sink.all.first)
        rig.requests.acknowledge(first.request, generation: first.generation, .shown)
        // Into the popover, resting on a word of its entry with the key still held.
        await rig.rest(at: UpPoint(x: 300, y: 400))
        rig.reader.answer(.word(HoverFixtures.hit("wave", bundleID: "ai.xdict.app"), request: rig.reader.asks[1].request,
                                key: "key-wave"))
        await HoverFixtures.settle { rig.sink.all.count == 2 }
        let second = try #require(rig.sink.all.last)
        #expect(second.term.term == "wave")
        #expect(second.request.number > first.request.number)
        #expect(rig.requests.isCurrent(second.request))
        #expect(rig.requests.terminal(of: first.request)?.outcome == .shown, "the first word's acknowledgement changed")
        rig.requests.acknowledge(second.request, generation: second.generation, .shown)
        await rig.drain()
        #expect(rig.reader.forgotten.isEmpty)
        #expect(rig.reader.remembered.count == 2)
    }

    /// **And one asked while the first word still draws supersedes it** (ADR-0014 d.4): the newer claim ends the first
    /// cancelled, whose word is forgotten (resting on it again asks again), and the first's late draw acknowledges nothing.
    @Test func aHoverInsideThePopoverWhileItsWordDrawsSupersedesIt() async throws {
        let rig = Rig()
        await rig.rest(at: UpPoint(x: 100, y: 100))
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { rig.sink.all.count == 1 }
        let first = try #require(rig.sink.all.first)
        await rig.rest(at: UpPoint(x: 300, y: 400))
        rig.reader.answer(.word(HoverFixtures.hit("wave", bundleID: "ai.xdict.app"), request: rig.reader.asks[1].request,
                                key: "key-wave"))
        await HoverFixtures.settle { rig.sink.all.count == 2 }
        #expect(rig.requests.terminal(of: first.request)?.outcome == .cancelled)
        await HoverFixtures.settle { !rig.reader.forgotten.isEmpty }
        #expect(rig.reader.forgotten == [rig.reader.remembered[0]], "the superseded word stayed remembered")
        #expect(!rig.requests.acknowledge(first.request, generation: first.generation, .shown),
                "the superseded word's late draw was taken as its acknowledgement")
    }

    /// **XDict's own events are watched as well as other apps'** (owner, 2026-10-19: hover works in XDict's own windows).
    /// A global monitor never sees an event sent to this app, so with XDict in front the hold key and the pointer reach
    /// hover only through a local monitor — for every watched kind, its event handed back, never swallowed, its window
    /// point taken to the screen. Red with the global monitors alone.
    @Test func ourOwnEventsAreWatchedAndHandedBack() throws {
        let monitors = RecordingMonitors()
        let events = SystemHoverEvents(monitors: monitors.monitors)
        var got: [HoverEvent] = []
        #expect(events.start { got.append($0) })
        #expect(monitors.global == SystemHoverEvents.watched.map(\.rawValue))
        #expect(monitors.local.map(\.mask) == SystemHoverEvents.watched.map(\.rawValue))
        #expect(monitors.removed == 0, "a monitor was removed while hover watches")
        let moved = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: CGPoint(x: 10, y: 20), modifierFlags: [], timestamp: 1, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        let local = try #require(monitors.local.first { $0.mask == NSEvent.EventTypeMask.mouseMoved.rawValue })
        #expect(local.handler(moved) === moved, "XDict's own event was swallowed")
        #expect(got == [.pointerMoved])
        events.stop()
        #expect(monitors.removed == 2 * SystemHoverEvents.watched.count)
    }

    /// **A local monitor that cannot be installed leaves none of either kind**: hover is off, not half on.
    @Test func aFailedLocalInstallRemovesEveryMonitor() {
        let monitors = RecordingMonitors()
        monitors.refuseLocal = true
        let events = SystemHoverEvents(monitors: monitors.monitors)
        #expect(!events.start { _ in })
        #expect(monitors.removed == monitors.global.count + monitors.local.count)
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

    /// **A hover presented after a shortcut that is still reading supersedes it** (WI-3 verification): the hover's word
    /// claims presentation, so the shortcut's late read is refused rather than shown over it. Red if the watcher hands its
    /// word over with `deliver`, which claims nothing.
    @Test func aHoverPresentedAfterAShortcutStillReadingSupersedesIt() async throws {
        let rig = Rig()
        let shortcut = rig.requests.beginPresenting(.selection)
        await rig.rest()
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { !rig.sink.all.isEmpty }
        let hover = try #require(rig.sink.all.first?.request)
        #expect(rig.requests.isCurrent(hover), "the hover's word did not claim presentation")
        let late = try CapturedTerm.make(term: "wave", trigger: .selection, acquisition: .textRange, confidence: 1,
                                         source: SourceApp(bundleID: nil), pointer: nil, box: .absent,
                                         context: .unavailable(.notCaptured))
        #expect(rig.requests.present(late, for: shortcut, to: rig.sink) == .refused,
                "an older shortcut's late read was presented over a newer hover")
    }

    // MARK: - The pixel path (plan-capture WI-4)

    /// **A notice for an abandoned read is not shown** (moved by name): hover stopped while the read was in flight, and
    /// its refusal for Screen Recording comes back after. Red if the watcher tells the notice unconditionally.
    @Test func aNoticeForAnAbandonedReadIsNotShown() async {
        let rig = Rig()
        var notices: [CaptureNotice] = []
        rig.watcher.onNotice = { notices.append($0) }
        await rig.rest()
        rig.watcher.stop()
        rig.reader.answer(.needsScreenRecording(request: rig.reader.asks[0].request))
        await rig.drain()
        #expect(notices.isEmpty)
    }

    /// **A notice for a hover that no longer stands is not shown** (moved by name from `HoverWatcherRoundTwoTests`): the
    /// pointer moved off before the read came back. Red if only cancellation is checked.
    @Test func aNoticeForAHoverThatNoLongerStandsIsNotShown() async {
        let rig = Rig()
        var notices: [CaptureNotice] = []
        rig.watcher.onNotice = { notices.append($0) }
        await rig.rest()
        rig.pointer.at = UpPoint(x: 600, y: 100)
        rig.events.emit(.pointerMoved)
        rig.reader.answer(.needsScreenRecording(request: rig.reader.asks[0].request))
        await rig.drain()
        #expect(notices.isEmpty)
    }

    /// **A notice whose request was ended first says nothing** (audit 2026-10-29 finding 6): Escape or a newer lookup
    /// ended it while the read was in flight, and the reader has moved past the miss. Red if the notice is told whatever
    /// the cancellation came to.
    @Test func aNoticeAfterItsRequestEndedIsNotShown() async {
        let rig = Rig()
        var notices: [CaptureNotice] = []
        rig.watcher.onNotice = { notices.append($0) }
        await rig.rest()
        let request = rig.reader.asks[0].request
        rig.requests.close()  // Escape, or the reader's own newer lookup
        rig.reader.answer(.needsScreenRecording(request: request))
        await rig.drain()
        #expect(notices.isEmpty, "a dismissed request's miss was announced")
        #expect(rig.requests.terminal(of: request)?.outcome == .cancelled)
    }

    /// **A notice for a hover that stands is told once, and its request ends** — nothing is presented for it.
    @Test func aNoticeIsToldAndItsRequestEnds() async {
        let rig = Rig()
        var notices: [CaptureNotice] = []
        rig.watcher.onNotice = { notices.append($0) }
        await rig.rest()
        rig.reader.answer(.needsScreenRecording(request: rig.reader.asks[0].request))
        await HoverFixtures.settle { !notices.isEmpty }
        #expect(notices == [.screenRecordingNeeded])
        #expect(rig.sink.all.isEmpty)
        #expect(rig.requests.terminal(of: rig.reader.asks[0].request)?.outcome == .cancelled)
    }

    /// **A read refused for a busy capture is asked again when the capture finishes** (moved by name), not when the
    /// pointer next twitches.
    @Test func aBlockedReadIsAskedAgainWhenTheCaptureFinishes() async {
        let rig = Rig()
        await rig.rest()
        rig.reader.answer(.quiet(.captureInFlight))
        await rig.drain()
        #expect(rig.reader.asks.count == 1)
        rig.reader.onCaptureReleased?()
        await rig.asks(2)
        #expect(rig.reader.asks.count == 2, "nothing asked again when the capture was released")
    }

    /// **A read asked again after a busy capture keeps its first number** (moved by name from `HoverWatcherRoundTwoTests`).
    /// Red if the re-ask takes a fresh one, which would let it claim presentation over a lookup made in between.
    @Test func aReAskKeepsItsNumber() async {
        let rig = Rig()
        await rig.rest()
        rig.reader.answer(.quiet(.captureInFlight))
        await rig.drain()
        rig.reader.onCaptureReleased?()
        await rig.asks(2)
        #expect(rig.reader.asks.map(\.request.number) == [rig.reader.asks[0].request.number, rig.reader.asks[0].request.number],
                "the re-ask was numbered \(rig.reader.asks.map(\.request.number))")
    }

    /// **A recognised word is presented with its context pending** (ADR-0014 d.2): acquisition `recognition`, the context
    /// the handle the consumer's session finds.
    @Test func aRecognisedWordIsPresentedWithItsContextPending() async throws {
        let rig = Rig()
        await rig.rest()
        let contexts = PendingContexts()
        let gate = GrowthGate()
        let context = contexts.start(fallback: .unavailable(.notCaptured), bound: RecognitionFixtures.patient, work: {
            await gate.held()
            return nil
        })
        rig.reader.answer(.recognised(RecognitionFixtures.recognition("He paid the fine."), request: rig.reader.asks[0].request,
                                      key: "key-fine", context: context))
        await HoverFixtures.settle { !rig.sink.all.isEmpty }
        let term = try #require(rig.sink.all.first?.term)
        #expect(term.term == "fine")
        #expect(term.acquisition == .recognition)
        #expect(term.context == .pending(context.handle))
        #expect(context.end == nil, "a presented context was cancelled")
        context.cancel()
    }

    /// **A recognised word that is not presented cancels its context** — it never outlives its request. Red if the drop
    /// path forgets the context.
    @Test func aRecognisedWordNotPresentedCancelsItsContext() async {
        let rig = Rig()
        await rig.rest()
        let contexts = PendingContexts()
        let context = contexts.start(fallback: .unavailable(.notCaptured), bound: RecognitionFixtures.patient, work: {
            await GrowthGate().held()
            return nil
        })
        rig.pointer.at = UpPoint(x: 600, y: 100)
        rig.events.emit(.pointerMoved)
        rig.reader.answer(.recognised(RecognitionFixtures.recognition("He paid the fine."), request: rig.reader.asks[0].request,
                                      key: "key-fine", context: context))
        await HoverFixtures.settle { context.end != nil }
        #expect(context.end == .cancelled, "a context nobody will see went on being read")
        #expect(rig.sink.all.isEmpty)
    }

    /// A context still being read, held until the test is done with it.
    private func reading(_ contexts: PendingContexts) -> PendingContext {
        contexts.start(fallback: .unavailable(.notCaptured), bound: RecognitionFixtures.patient, work: {
            await GrowthGate().held()
            return nil
        })
    }

    /// **A recognised word whose presentation is refused cancels its context**: a newer request took the presentation
    /// after this hover's was numbered, so the hover's word is refused — and the sentence read for it is let go and leaves
    /// the book. Red if the refused-presentation path forgets the discard.
    @Test func aRecognisedWordRefusedThePresentationCancelsItsContext() async {
        let rig = Rig()
        await rig.rest()
        _ = rig.requests.beginPresenting(.selection)
        let contexts = PendingContexts()
        let context = reading(contexts)
        rig.reader.answer(.recognised(RecognitionFixtures.recognition("He paid the fine."), request: rig.reader.asks[0].request,
                                      key: "key-fine", context: context))
        await HoverFixtures.settle { context.end != nil }
        #expect(context.end == .cancelled, "a word refused the presentation kept its sentence being read")
        #expect(contexts.count == 0, "the book kept a refused word's context")
        #expect(rig.sink.all.isEmpty)
    }

    /// **A recognised word the validating constructor refuses cancels its context**: a control character in the word is
    /// never a term, and the sentence read for it is let go and leaves the book. Red if the refused-term path forgets the
    /// discard.
    @Test func aRecognisedWordRefusedAsATermCancelsItsContext() async throws {
        let rig = Rig()
        await rig.rest()
        let contexts = PendingContexts()
        let context = reading(contexts)
        let sentence = "He paid the fi\u{1}ne."
        let words = try #require(SentenceContext(text: sentence, mayBeCut: false,
                                                 selection: (sentence as NSString).range(of: "fi\u{1}ne"), cut: []))
        let refused = Recognition(word: WordAtPoint(word: "fi\u{1}ne", sentence: words), confidence: 0.9, mayBeCut: false,
                                  appName: "Ghostty", bundleID: "com.mitchellh.ghostty", gap: nil)
        rig.reader.answer(.recognised(refused, request: rig.reader.asks[0].request, key: "key-refused", context: context))
        await HoverFixtures.settle { context.end != nil }
        #expect(context.end == .cancelled, "a refused term kept its sentence being read")
        #expect(contexts.count == 0, "the book kept a refused term's context")
        #expect(rig.sink.all.isEmpty)
    }

    /// **A read that found nothing ends its request** (new in XDict: every request ends exactly once, ADR-0014 d.4).
    @Test func aReadThatFoundNothingEndsItsRequest() async {
        let rig = Rig()
        await rig.rest()
        rig.reader.answer(.nothing(.miss(.noText(app: "TextEdit", role: nil))))
        await rig.drain()
        #expect(rig.requests.terminal(of: rig.reader.asks[0].request)?.outcome == .cancelled)
    }

    /// **A hover that stands and found nothing says so** (owner's report, 2026-10-19: "nothing visible happens on a
    /// miss"): the kind alone, no word and no sentence, told once; nothing is presented and its request ends. Red while a
    /// miss ended in silence.
    @Test func aHoverThatFoundNothingIsToldSo() async {
        let rig = Rig()
        var notices: [CaptureNotice] = []
        rig.watcher.onNotice = { notices.append($0) }
        await rig.rest()
        rig.reader.answer(.nothing(.miss(.noText(app: "TextEdit", role: "AXGroup"))))
        await HoverFixtures.settle { !notices.isEmpty }
        #expect(notices == [.nothingUnderPointer])
        #expect(rig.sink.all.isEmpty)
        #expect(rig.requests.terminal(of: rig.reader.asks[0].request)?.outcome == .cancelled)
    }

    /// **A miss over XDict's own window is said where the pointer is** (owner's question, 2026-10-24): the word may be
    /// in the app behind XDict, so the notice is not the generic "nothing here".
    /// A capture that did not answer in time is not "nothing here": it is told as the stuck capture it is.
    @Test func aCaptureThatTimedOutIsToldAsStuck() async {
        let rig = Rig()
        var notices: [CaptureNotice] = []
        rig.watcher.onNotice = { notices.append($0) }
        await rig.rest()
        rig.reader.answer(.nothing(.captureTimedOut))
        await HoverFixtures.settle { !notices.isEmpty }
        #expect(notices == [.captureStuck])
    }

    /// The control: a miss for a hover the reader already left is not told.
    @Test func aMissForAHoverThatNoLongerStandsIsNotTold() async {
        let rig = Rig()
        var notices: [CaptureNotice] = []
        rig.watcher.onNotice = { notices.append($0) }
        await rig.rest()
        rig.pointer.at = UpPoint(x: 600, y: 100)
        rig.events.emit(.pointerMoved)
        rig.reader.answer(.nothing(.miss(.noText(app: "TextEdit", role: nil))))
        await rig.drain()
        #expect(notices.isEmpty)
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
                                   contexts: PendingContexts(), restTolerance: HoverFixtures.rest)
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

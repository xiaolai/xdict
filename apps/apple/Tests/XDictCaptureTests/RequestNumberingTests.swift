import Foundation
import Synchronization
import Testing
@testable import XDictCapture

/// **One numbering for every trigger, in one order** (ADR-0014 decision 4; plan-capture WI-3, carried from WI-1's
/// verification): `RequestSequence`'s presentation claims and `CaptureRequests`' acknowledgements were two counters, so a
/// hover's number and a shortcut's could not be compared. Now `CaptureRequests` hands out the one number, and claiming
/// presentation stays a separate act on it (XiaolaiDict ADR-0045): a hover is numbered at its gesture and claims only
/// when its word is presented; the shortcut, the Service and the menu number and claim at once.
struct RequestNumberingTests {
    final class Consumer: CaptureSink {
        let delivered = Mutex<[CaptureDelivery]>([])
        func deliver(_ delivery: CaptureDelivery) -> CaptureDeliveryAnswer {
            delivered.withLock { $0.append(delivery) }
            return .accepted
        }
        var generations: [Int: Int] {
            delivered.withLock { Dictionary($0.map { ($0.request.number, $0.generation) }, uniquingKeysWith: { $1 }) }
        }
    }

    private func term(_ word: String, _ trigger: CaptureTrigger) throws -> CapturedTerm {
        try CapturedTerm.make(term: word, trigger: trigger, acquisition: .textRange, confidence: 1,
                              source: SourceApp(bundleID: nil), pointer: nil, box: .absent,
                              context: .unavailable(.notCaptured))
    }

    /// **Shortcut, Service, menu and hover through one book**: numbered in the order asked, whatever the trigger; each
    /// later claim supersedes every request before it, and each request ends exactly once — the three superseded ones
    /// cancelled, the last shown. Red while the hover's number comes from a counter of its own.
    @Test func everyTriggerIsNumberedInOneOrderAndEndsOnce() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let hover = requests.begin(.pointerGesture)
        let shortcut = requests.beginPresenting(.selection)
        let service = requests.beginPresenting(.service)
        let menu = requests.beginPresenting(.menu)
        #expect([hover, shortcut, service, menu].map(\.number) == [1, 2, 3, 4])
        #expect([hover, shortcut, service, menu].map(\.trigger) == [.pointerGesture, .selection, .service, .menu])

        // The older three can no longer be presented; the newest can.
        #expect(requests.present(try term("hold", .pointerGesture), for: hover, to: consumer) == .refused)
        #expect(requests.present(try term("tide", .selection), for: shortcut, to: consumer) == .refused)
        #expect(requests.present(try term("wave", .service), for: service, to: consumer) == .refused)
        #expect(requests.present(try term("surf", .menu), for: menu, to: consumer) == .accepted)
        #expect(consumer.delivered.withLock { $0.map(\.term.term) } == ["surf"], "a superseded request reached the sink")
        let generation = try #require(consumer.generations[menu.number])
        #expect(requests.acknowledge(menu, generation: generation, .shown))

        #expect(requests.terminal(of: hover)?.outcome == .cancelled)
        #expect(requests.terminal(of: shortcut)?.outcome == .cancelled)
        #expect(requests.terminal(of: service)?.outcome == .cancelled)
        #expect(requests.terminal(of: menu) == CaptureAcknowledgement(request: 4, generation: generation, outcome: .shown))
        for request in [hover, shortcut, service, menu] {
            #expect(!requests.cancel(request), "request \(request.number) ended twice")
        }
    }

    /// **The race ADR-0045 closes, now across triggers**: a hover numbered before a shortcut loses to it, even though its
    /// word arrives last; a hover numbered after the shortcut's presentation takes over, and the shortcut's delivered
    /// request ends cancelled rather than waiting for an acknowledgement nobody will send.
    @Test func aHoverNumberedBeforeAShortcutLosesAndOneNumberedAfterWins() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let early = requests.begin(.pointerGesture)
        let shortcut = requests.beginPresenting(.selection)
        #expect(requests.present(try term("tide", .selection), for: shortcut, to: consumer) == .accepted)
        #expect(requests.present(try term("hold", .pointerGesture), for: early, to: consumer) == .refused)
        #expect(requests.isCurrent(shortcut))

        let late = requests.begin(.pointerGesture)
        #expect(late.number > shortcut.number)
        #expect(requests.present(try term("wave", .pointerGesture), for: late, to: consumer) == .accepted)
        #expect(requests.isCurrent(late) && !requests.isCurrent(shortcut))
        #expect(requests.terminal(of: shortcut)?.outcome == .cancelled, "the shortcut's request was left open")
        let stale = try #require(consumer.generations[shortcut.number])
        #expect(!requests.acknowledge(shortcut, generation: stale, .shown), "a superseded request was shown")
    }

    /// **A request presented again keeps its claim**: the same request delivered a second time (a hover re-read at the
    /// same word) is still current, not refused by its own earlier claim.
    @Test func theCurrentRequestMayBePresentedAgain() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let shortcut = requests.beginPresenting(.selection)
        #expect(requests.present(try term("tide", .selection), for: shortcut, to: consumer) == .accepted)
        #expect(requests.present(try term("tide", .selection), for: shortcut, to: consumer) == .accepted)
        #expect(requests.terminal(of: shortcut) == nil)
    }

    /// **Closing supersedes everything handed out so far**: every open request ends cancelled, delivered or not, and a
    /// result arriving afterwards is not presented over the reader's dismissal.
    @Test func closingEndsEveryOpenRequestAndRefusesLateResults() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let shown = requests.beginPresenting(.selection)
        _ = requests.present(try term("tide", .selection), for: shown, to: consumer)
        let reading = requests.begin(.pointerGesture)
        let ended = requests.close()
        #expect(ended.map(\.request) == [shown.number, reading.number])
        #expect(ended.allSatisfy { $0.outcome == .cancelled })
        #expect(requests.present(try term("hold", .pointerGesture), for: reading, to: consumer) == .refused)
        #expect(!requests.isCurrent(shown))
    }

    /// **Every ending is told, once, with its number and generation** — the hover watcher forgets a word nobody saw by it.
    @Test func everyEndingIsToldOnce() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let told = Mutex<[CaptureAcknowledgement]>([])
        requests.onEnd { ack in told.withLock { $0.append(ack) } }
        let hover = requests.begin(.pointerGesture)
        let shortcut = requests.beginPresenting(.selection)
        _ = requests.present(try term("tide", .selection), for: shortcut, to: consumer)
        let generation = try #require(consumer.generations[shortcut.number])
        requests.acknowledge(shortcut, generation: generation, .notShown)
        requests.acknowledge(shortcut, generation: generation, .shown)
        #expect(told.withLock { $0 } == [
            CaptureAcknowledgement(request: hover.number, generation: 0, outcome: .cancelled),
            CaptureAcknowledgement(request: shortcut.number, generation: generation, outcome: .notShown),
        ])
    }
}

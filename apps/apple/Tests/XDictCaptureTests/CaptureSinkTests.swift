import Foundation
import Synchronization
import Testing
@testable import XDictCapture

/// **The identified sink** (ADR-0014 decision 4; Codex: `accepted|refused` plus an unqualified `shown(Bool)` raced):
/// requests numbered synchronously, exactly one terminal acknowledgement per request carrying its number and the
/// result's generation, a refusal that cancels, and a consumer that disappears.
struct CaptureSinkTests {
    /// A consumer of the tests' own: answers as told and remembers what it was handed.
    final class Consumer: CaptureSink {
        let answer: CaptureDeliveryAnswer
        let delivered = Mutex<[CaptureDelivery]>([])
        init(answer: CaptureDeliveryAnswer = .accepted) { self.answer = answer }
        func deliver(_ delivery: CaptureDelivery) -> CaptureDeliveryAnswer {
            delivered.withLock { $0.append(delivery) }
            return answer
        }
    }

    private func term(_ word: String = "hold") throws -> CapturedTerm {
        try CapturedTerm.make(term: word, trigger: .pointerGesture, acquisition: .textRange, confidence: 1,
                              source: SourceApp(bundleID: nil), pointer: nil, box: .absent,
                              context: .unavailable(.notCaptured))
    }

    @Test func requestsAreNumberedSynchronouslyInOrder() {
        let requests = CaptureRequests()
        let first = requests.begin(.pointerGesture)
        let second = requests.begin(.selection)
        #expect(second.number == first.number + 1, "numbered at the call, before any capture runs")
        #expect(first.trigger == .pointerGesture && second.trigger == .selection)
    }

    @Test func aDeliveryCarriesItsRequestAndAGeneration() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let request = requests.begin(.service)
        #expect(requests.deliver(try term(), for: request, to: consumer) == .accepted)
        let handed = try #require(consumer.delivered.withLock { $0.first })
        #expect(handed.request == request)
        #expect(handed.generation > 0)
        #expect(requests.acknowledge(request, generation: handed.generation, .shown))
        #expect(requests.terminal(of: request) == CaptureAcknowledgement(request: request.number,
                                                                          generation: handed.generation, outcome: .shown))
    }

    /// **Exactly one terminal acknowledgement**: a second, or one of another generation, changes nothing.
    @Test func aDuplicateAcknowledgementIsIgnored() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let request = requests.begin(.pointerGesture)
        _ = requests.deliver(try term(), for: request, to: consumer)
        let generation = try #require(consumer.delivered.withLock { $0.first?.generation })
        #expect(requests.acknowledge(request, generation: generation, .shown))
        #expect(!requests.acknowledge(request, generation: generation, .notShown))
        #expect(!requests.acknowledge(request, generation: generation + 1, .cancelled))
        #expect(requests.terminal(of: request)?.outcome == .shown)
    }

    /// **A late answer of one request never changes another's**: A's acknowledgement arriving after B's.
    @Test func aLateAcknowledgementOfAAfterBChangesOnlyA() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let a = requests.begin(.pointerGesture), b = requests.begin(.pointerGesture)
        _ = requests.deliver(try term("alpha"), for: a, to: consumer)
        _ = requests.deliver(try term("beta"), for: b, to: consumer)
        let generations = consumer.delivered.withLock { $0.map(\.generation) }
        #expect(requests.acknowledge(b, generation: generations[1], .shown))
        #expect(requests.acknowledge(a, generation: generations[0], .notShown))
        #expect(requests.terminal(of: b)?.outcome == .shown)
        #expect(requests.terminal(of: a)?.outcome == .notShown)
        #expect(!requests.acknowledge(a, generation: generations[1], .shown), "B's generation is not A's")
    }

    /// Two requests for the same word, acknowledged in reverse: each settles on its own number.
    @Test func sameWordRequestsAcknowledgedInReverseSettleApart() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let first = requests.begin(.pointerGesture), second = requests.begin(.pointerGesture)
        _ = requests.deliver(try term(), for: first, to: consumer)
        _ = requests.deliver(try term(), for: second, to: consumer)
        let generations = consumer.delivered.withLock { $0.map(\.generation) }
        #expect(generations[0] != generations[1])
        #expect(requests.acknowledge(second, generation: generations[1], .notShown))
        #expect(requests.acknowledge(first, generation: generations[0], .shown))
        #expect(requests.terminal(of: first)?.outcome == .shown)
        #expect(requests.terminal(of: second)?.outcome == .notShown)
    }

    /// **A refusal cancels**: the request ends cancelled, and its later acknowledgement changes nothing.
    @Test func aRefusalCancelsTheRequest() throws {
        let requests = CaptureRequests(), consumer = Consumer(answer: .refused)
        let request = requests.begin(.menu)
        #expect(requests.deliver(try term(), for: request, to: consumer) == .refused)
        #expect(requests.terminal(of: request)?.outcome == .cancelled)
        let generation = try #require(consumer.delivered.withLock { $0.first?.generation })
        #expect(!requests.acknowledge(request, generation: generation, .shown))
    }

    /// **Escape before delivery**: the request is cancelled, and a result arriving afterwards is not handed over.
    @Test func escapeBeforeDeliveryCancelsAndTheResultIsNotDelivered() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let request = requests.begin(.pointerGesture)
        #expect(requests.cancel(request))
        #expect(!requests.cancel(request), "one terminal acknowledgement")
        #expect(requests.deliver(try term(), for: request, to: consumer) == .refused)
        #expect(consumer.delivered.withLock { $0.isEmpty })
        #expect(requests.terminal(of: request)?.outcome == .cancelled)
    }

    /// **The consumer disappears**: a delivery to nobody is refused and cancelled, and every request still open ends
    /// cancelled when it is gone.
    @Test func aConsumerThatDisappearsCancelsWhatIsOpen() throws {
        let requests = CaptureRequests()
        let delivered = requests.begin(.pointerGesture), open = requests.begin(.selection)
        weak var gone: Consumer?
        do {
            let consumer = Consumer()
            gone = consumer
            _ = requests.deliver(try term(), for: delivered, to: consumer)
        }
        #expect(gone == nil)
        #expect(requests.deliver(try term(), for: open, to: gone) == .refused)
        #expect(requests.terminal(of: open)?.outcome == .cancelled)
        let ended = requests.consumerGone()
        #expect(ended.map(\.request) == [delivered.number])
        #expect(ended.allSatisfy { $0.outcome == .cancelled })
        #expect(requests.terminal(of: delivered)?.outcome == .cancelled)
    }

    /// **A stale generation never ends an open request**: delivered twice, the first delivery's acknowledgement is
    /// refused and the request stays open for the second's.
    @Test func aStaleGenerationLeavesTheRequestOpen() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let request = requests.begin(.pointerGesture)
        _ = requests.deliver(try term(), for: request, to: consumer)
        _ = requests.deliver(try term("held"), for: request, to: consumer)
        let generations = consumer.delivered.withLock { $0.map(\.generation) }
        #expect(generations.count == 2 && generations[0] != generations[1])
        #expect(!requests.acknowledge(request, generation: generations[0], .shown), "the stale generation was taken")
        #expect(requests.terminal(of: request) == nil, "the request ended on a stale answer")
        #expect(requests.acknowledge(request, generation: generations[1], .notShown))
        #expect(requests.terminal(of: request)?.outcome == .notShown)
    }

    /// **An acknowledgement before any delivery is refused**, and the request stays open to be delivered.
    @Test func anAcknowledgementBeforeDeliveryIsRefused() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let request = requests.begin(.selection)
        #expect(!requests.acknowledge(request, generation: 1, .shown))
        #expect(requests.terminal(of: request) == nil)
        #expect(requests.deliver(try term(), for: request, to: consumer) == .accepted)
    }

    /// **Bounded**: a long run of requests keeps only the open ones and a small ring of recently ended numbers.
    @Test func aLongRunOfRequestsDoesNotGrowTheBook() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let word = try term()
        for _ in 0..<5_000 {
            let request = requests.begin(.pointerGesture)
            _ = requests.deliver(word, for: request, to: consumer)
            let generation = try #require(consumer.delivered.withLock { $0.last?.generation })
            requests.acknowledge(request, generation: generation, .shown)
            consumer.delivered.withLock { $0.removeAll() }
        }
        let open = requests.begin(.menu)
        _ = requests.deliver(word, for: open, to: consumer)
        #expect(requests.retained.open == 1)
        #expect(requests.retained.ended <= CaptureRequests.endedMemory)
        // A request older than the ring is stale: never delivered and never acknowledged.
        let ancient = CaptureRequest(number: 1, trigger: .pointerGesture)
        #expect(requests.deliver(word, for: ancient, to: consumer) == .refused)
        #expect(!requests.acknowledge(ancient, generation: 1, .shown))
    }

    /// Ends `count` other requests, each begun, delivered and acknowledged.
    private func endOthers(_ count: Int, in requests: CaptureRequests, consumer: Consumer) throws {
        for _ in 0..<count {
            let other = requests.begin(.pointerGesture)
            _ = requests.deliver(try term(), for: other, to: consumer)
            let generation = try #require(consumer.delivered.withLock { $0.last?.generation })
            requests.acknowledge(other, generation: generation, .shown)
        }
    }

    /// **A request begun and not yet delivered outlives any number of others' endings**: the ring holds ended
    /// requests only, so it is still delivered and acknowledged exactly once.
    @Test func aLongWaitingRequestIsStillDeliveredAndAcknowledgedOnce() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let waiting = requests.begin(.selection)
        try endOthers(70, in: requests, consumer: consumer)
        #expect(requests.deliver(try term(), for: waiting, to: consumer) == .accepted)
        let generation = try #require(consumer.delivered.withLock { $0.last?.generation })
        #expect(requests.acknowledge(waiting, generation: generation, .shown))
        #expect(!requests.acknowledge(waiting, generation: generation, .shown))
        #expect(requests.terminal(of: waiting)?.outcome == .shown)
    }

    @Test func aLongWaitingRequestIsStillCancelledOnce() throws {
        let requests = CaptureRequests(), consumer = Consumer()
        let waiting = requests.begin(.selection)
        try endOthers(70, in: requests, consumer: consumer)
        #expect(requests.cancel(waiting))
        #expect(!requests.cancel(waiting))
        #expect(requests.terminal(of: waiting)?.outcome == .cancelled)
    }

    @Test func anUnknownRequestIsNeverAcknowledged() {
        let requests = CaptureRequests()
        let stranger = CaptureRequest(number: 99, trigger: .menu)
        #expect(!requests.acknowledge(stranger, generation: 1, .shown))
        #expect(!requests.cancel(stranger))
        #expect(requests.terminal(of: stranger) == nil)
    }
}

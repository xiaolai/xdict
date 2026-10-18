import Synchronization

/// One request to capture, numbered **when it is asked**, before any asynchronous capture runs (ADR-0014 decision 4;
/// XiaolaiDict ADR-0045: numbering is separate from claiming presentation).
public struct CaptureRequest: Sendable, Hashable {
    public let number: Int
    public let trigger: CaptureTrigger

    public init(number: Int, trigger: CaptureTrigger) {
        self.number = number
        self.trigger = trigger
    }
}

/// What a consumer is handed: the term, the request it answers, and this result's generation.
public struct CaptureDelivery: Sendable, Equatable {
    public let term: CapturedTerm
    public let request: CaptureRequest
    public let generation: Int
}

public enum CaptureDeliveryAnswer: Sendable, Equatable {
    case accepted
    /// Not taken. The request ends cancelled.
    case refused
}

/// How a request ended. "Shown" is the consumer's to say: an invisible anchor window never counts, and a popover
/// reported shown is not a draw of the new content.
public enum CaptureOutcome: String, Sendable, Equatable {
    case shown, notShown, cancelled
}

/// A request's one terminal acknowledgement, with its number and the generation it was given for.
public struct CaptureAcknowledgement: Sendable, Equatable {
    public let request: Int
    public let generation: Int
    public let outcome: CaptureOutcome

    public init(request: Int, generation: Int, outcome: CaptureOutcome) {
        self.request = request
        self.generation = generation
        self.outcome = outcome
    }
}

/// **Whoever receives captured terms.** It answers at once whether it took one; whether it was then shown comes back
/// later through `CaptureRequests.acknowledge`, for that request and generation only.
public protocol CaptureSink: AnyObject, Sendable {
    func deliver(_ delivery: CaptureDelivery) -> CaptureDeliveryAnswer
}

/// **The requests of every trigger, and the rule that each ends exactly once** (shortcut, Service, menu and hover alike).
///
/// - `begin` numbers synchronously, under the lock, in the order asked.
/// - `deliver` stamps a fresh generation and hands the term over; a request already ended, or a consumer that is gone,
///   is refused — and a refusal ends the request cancelled.
/// - `acknowledge` records the first terminal answer whose generation is the request's **latest delivery**; an answer
///   before any delivery, for an older generation, a duplicate, or one after a cancel changes nothing and says so.
/// - `cancel` (Escape, a newer shortcut) ends a request not yet ended; `consumerGone` ends every delivered request still
///   open.
///
/// **Bounded by what is still owed.** Every request begun and not yet ended is kept (delivered or not), and of the
/// ended ones only the last `endedMemory` numbers, for duplicate and late answers. A number at or below one that fell
/// out of that ring, and not open, has ended.
public final class CaptureRequests: Sendable {
    private struct State {
        var issued = 0
        var generations = 0
        /// Every request begun and not ended, with the generation of its latest delivery; 0 is not yet delivered
        /// (generations start at 1).
        var open: [Int: Int] = [:]
        /// Recently ended requests, oldest first in `endedOrder`.
        var ended: [Int: CaptureAcknowledgement] = [:]
        var endedOrder: [Int] = []
        /// The highest number that fell out of the ended ring.
        var forgottenThrough = 0

        func known(_ request: CaptureRequest) -> Bool { request.number > 0 && request.number <= issued }

        func isEnded(_ number: Int) -> Bool {
            ended[number] != nil || (number <= forgottenThrough && open[number] == nil)
        }

        mutating func end(_ number: Int, generation: Int, _ outcome: CaptureOutcome) -> CaptureAcknowledgement? {
            guard !isEnded(number) else { return nil }
            open[number] = nil
            let ack = CaptureAcknowledgement(request: number, generation: generation, outcome: outcome)
            ended[number] = ack
            endedOrder.append(number)
            if endedOrder.count > CaptureRequests.endedMemory {
                let gone = endedOrder.removeFirst()
                ended[gone] = nil
                forgottenThrough = max(forgottenThrough, gone)
            }
            return ack
        }
    }

    /// How many ended numbers are remembered, for duplicate and late answers. A count, not a design value.
    static let endedMemory = 64

    private let state = Mutex(State())

    public init() {}

    public func begin(_ trigger: CaptureTrigger) -> CaptureRequest {
        state.withLock { state in
            state.issued += 1
            state.open[state.issued] = 0
            return CaptureRequest(number: state.issued, trigger: trigger)
        }
    }

    /// Hands `term` to `sink` for `request`. The sink is called outside the lock, so a sink that acknowledges at once
    /// cannot deadlock.
    public func deliver(_ term: CapturedTerm, for request: CaptureRequest, to sink: (any CaptureSink)?) -> CaptureDeliveryAnswer {
        let generation: Int? = state.withLock { state in
            guard state.known(request), !state.isEnded(request.number) else { return nil }
            state.generations += 1
            state.open[request.number] = state.generations
            return state.generations
        }
        guard let generation else { return .refused }
        guard let sink else {
            _ = state.withLock { $0.end(request.number, generation: generation, .cancelled) }
            return .refused
        }
        let answer = sink.deliver(CaptureDelivery(term: term, request: request, generation: generation))
        if answer == .refused { _ = state.withLock { $0.end(request.number, generation: generation, .cancelled) } }
        return answer
    }

    /// True where this answer became the request's terminal acknowledgement.
    @discardableResult
    public func acknowledge(_ request: CaptureRequest, generation: Int, _ outcome: CaptureOutcome) -> Bool {
        state.withLock { state in
            guard state.known(request), generation > 0, state.open[request.number] == generation else { return false }
            return state.end(request.number, generation: generation, outcome) != nil
        }
    }

    /// Ends a request not yet ended, delivered or not. True where it did.
    @discardableResult
    public func cancel(_ request: CaptureRequest) -> Bool {
        state.withLock { state in
            guard state.known(request) else { return false }
            return state.end(request.number, generation: state.open[request.number] ?? 0, .cancelled) != nil
        }
    }

    /// The consumer is gone: every delivered request still open ends cancelled, in order. Requests not yet delivered stay
    /// open, and their delivery to nobody is refused.
    public func consumerGone() -> [CaptureAcknowledgement] {
        state.withLock { state in
            state.open.filter { $0.value > 0 }.sorted { $0.key < $1.key }
                .compactMap { state.end($0.key, generation: $0.value, .cancelled) }
        }
    }

    public func terminal(of request: CaptureRequest) -> CaptureAcknowledgement? {
        state.withLock { $0.known(request) ? $0.ended[request.number] : nil }
    }

    /// How much the book holds, for the bound's test.
    var retained: (open: Int, ended: Int) {
        state.withLock { ($0.open.count, $0.ended.count) }
    }
}

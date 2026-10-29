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

/// **The requests of every trigger, numbered once, and the rule that each ends exactly once** (shortcut, Service, menu and
/// hover alike).
///
/// **One numbering** (plan-capture WI-3): the number `begin` hands out is also the one presentation is claimed with
/// (`RequestSequence`, held inside), so a hover and a shortcut are ordered by when the reader asked, whatever triggered
/// them. Numbering and claiming stay two acts (XiaolaiDict ADR-0045).
///
/// - `begin` numbers synchronously, under the lock, in the order asked; `beginPresenting` numbers and claims at once, for
///   a request the reader made where nothing can overtake it (the shortcut, the Service, the menu).
/// - `present` claims presentation for a request numbered earlier (a hover) and delivers; a claim refused — a later
///   request claimed, or presentation closed since — ends the request cancelled without asking the sink. **A successful
///   claim ends every open request numbered below it**, cancelled: none of them can be presented any more.
/// - `close` (the reader dismissed what was presented) ends every open request, delivered or not.
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
        /// The one numbering, and the presentation claims made on it.
        var sequence = RequestSequence()
        var generations = 0
        /// Every request begun and not ended, with the generation of its latest delivery; 0 is not yet delivered
        /// (generations start at 1).
        var open: [Int: Int] = [:]
        /// Recently ended requests, oldest first in `endedOrder`.
        var ended: [Int: CaptureAcknowledgement] = [:]
        var endedOrder: [Int] = []
        /// The highest number that fell out of the ended ring.
        var forgottenThrough = 0

        func known(_ request: CaptureRequest) -> Bool { request.number > 0 && request.number <= sequence.issued }

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

        /// Ends every open request numbered below `number`, in order.
        mutating func endBelow(_ number: Int) -> [CaptureAcknowledgement] {
            open.filter { $0.key < number }.sorted { $0.key < $1.key }
                .compactMap { end($0.key, generation: $0.value, .cancelled) }
        }
    }

    /// How many ended numbers are remembered, for duplicate and late answers. A count, not a design value.
    static let endedMemory = 64

    private let state = Mutex(State())

    /// Who is told each ending: set once by the composition layer (the hover watcher forgets a word nobody saw).
    private let listener = Mutex<(@Sendable (CaptureAcknowledgement) -> Void)?>(nil)

    public init() {}

    /// Tells `handler` every terminal acknowledgement from now on, once each, on the thread that ended it and outside the
    /// lock. Replaces any handler set before.
    public func onEnd(_ handler: @escaping @Sendable (CaptureAcknowledgement) -> Void) {
        listener.withLock { $0 = handler }
    }

    private func tell(_ endings: [CaptureAcknowledgement]) {
        guard !endings.isEmpty, let handler = listener.withLock({ $0 }) else { return }
        for ack in endings { handler(ack) }
    }

    /// A number, now, which claims nothing until `present`.
    public func begin(_ trigger: CaptureTrigger) -> CaptureRequest {
        state.withLock { state in
            let number = state.sequence.begin()
            state.open[number] = 0
            return CaptureRequest(number: number, trigger: trigger)
        }
    }

    /// A number that claims presentation at once, ending every open request before it.
    public func beginPresenting(_ trigger: CaptureTrigger) -> CaptureRequest {
        let (request, endings) = state.withLock { state in
            let number = state.sequence.next()
            state.open[number] = 0
            return (CaptureRequest(number: number, trigger: trigger), state.endBelow(number))
        }
        tell(endings)
        return request
    }

    /// Claims presentation for `request` — kept where it is already the presented one — and delivers `term` to `sink`.
    /// A refused claim ends the request cancelled and never reaches the sink.
    public func present(_ term: CapturedTerm, for request: CaptureRequest, to sink: (any CaptureSink)?) -> CaptureDeliveryAnswer {
        let (claimed, endings) = state.withLock { state -> (Bool, [CaptureAcknowledgement]) in
            guard state.known(request), !state.isEnded(request.number) else { return (false, []) }
            if state.sequence.isCurrent(request.number) { return (true, []) }
            // Fail-closed, unreachable today: every claim ends the open requests below it (`endBelow`) and `close` ends
            // them all, so an open request is never older than the presented one. Kept so a change to that invariant
            // refuses and ends the request rather than presenting it out of order.
            guard state.sequence.claim(request.number) else {
                return (false, state.end(request.number, generation: state.open[request.number] ?? 0, .cancelled).map { [$0] } ?? [])
            }
            return (true, state.endBelow(request.number))
        }
        tell(endings)
        guard claimed else {
            Diagnostics.shared.record("request.refused", ["request": "\(request.number)",
                                                          "trigger": request.trigger.rawValue])
            return .refused
        }
        return deliver(term, for: request, to: sink)
    }

    /// The reader dismissed what was presented: every open request ends cancelled, in order, and none numbered so far
    /// may claim presentation again.
    @discardableResult
    public func close() -> [CaptureAcknowledgement] {
        let endings = state.withLock { state in
            state.sequence.close()
            return state.endBelow(Int.max)
        }
        tell(endings)
        return endings
    }

    /// Whether `request` is the one presented.
    public func isCurrent(_ request: CaptureRequest) -> Bool {
        state.withLock { $0.known(request) && $0.sequence.isCurrent(request.number) }
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
            endIfCurrent(request, generation: generation)
            return .refused
        }
        let answer = sink.deliver(CaptureDelivery(term: term, request: request, generation: generation))
        if answer == .refused {
            endIfCurrent(request, generation: generation)
        }
        return answer
    }

    /// Ends the request cancelled **only while this delivery is still the request's latest** (audit 2026-10-29 finding
    /// 3): the sink runs outside the lock, so an older delivery's refusal can come back after a newer delivery of the
    /// same request went out — ending on the old generation would cancel the newer one, which is the one still owed.
    private func endIfCurrent(_ request: CaptureRequest, generation: Int) {
        let ended = state.withLock { state -> CaptureAcknowledgement? in
            guard state.open[request.number] == generation else { return nil }
            return state.end(request.number, generation: generation, .cancelled)
        }
        tell(ended.map { [$0] } ?? [])
    }

    /// True where this answer became the request's terminal acknowledgement.
    @discardableResult
    public func acknowledge(_ request: CaptureRequest, generation: Int, _ outcome: CaptureOutcome) -> Bool {
        let ended = state.withLock { state -> CaptureAcknowledgement? in
            guard state.known(request), generation > 0, state.open[request.number] == generation else { return nil }
            return state.end(request.number, generation: generation, outcome)
        }
        tell(ended.map { [$0] } ?? [])
        return ended != nil
    }

    /// Ends a request not yet ended, delivered or not. True where it did.
    @discardableResult
    public func cancel(_ request: CaptureRequest) -> Bool {
        let ended = state.withLock { state -> CaptureAcknowledgement? in
            guard state.known(request) else { return nil }
            return state.end(request.number, generation: state.open[request.number] ?? 0, .cancelled)
        }
        tell(ended.map { [$0] } ?? [])
        return ended != nil
    }

    /// The consumer is gone: every delivered request still open ends cancelled, in order. Requests not yet delivered stay
    /// open, and their delivery to nobody is refused.
    public func consumerGone() -> [CaptureAcknowledgement] {
        let endings = state.withLock { state in
            state.open.filter { $0.value > 0 }.sorted { $0.key < $1.key }
                .compactMap { state.end($0.key, generation: $0.value, .cancelled) }
        }
        tell(endings)
        return endings
    }

    public func terminal(of request: CaptureRequest) -> CaptureAcknowledgement? {
        state.withLock { $0.known(request) ? $0.ended[request.number] : nil }
    }

    /// How much the book holds, for the bound's test.
    var retained: (open: Int, ended: Int) {
        state.withLock { ($0.open.count, $0.ended.count) }
    }
}

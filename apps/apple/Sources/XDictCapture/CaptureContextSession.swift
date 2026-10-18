import Synchronization

/// **The one ephemeral session a captured sentence lives in** (ADR-0014 decision 9): owned by the capture side, handed
/// the context of the request being presented, and nothing else. Only the term goes to search, the service, the trail and
/// the observation hooks; the context stays here.
///
/// - **One context at a time**: the next presentation's replaces it.
/// - **In memory only**: nothing here is `Codable`, nothing writes it anywhere, and presentation's end drops it.
/// - **Metadata only in every description** (`CustomStringConvertible`, `CustomDebugStringConvertible`, an empty
///   mirror), so a log line, a `dump` or an observation hook that touches the session writes no word of the sentence.
///   `.private` logging is still logging; the guarantee is no persistence or diagnostic written by the application.
public final class CaptureContextSession: Sendable {
    private struct Held: Sendable {
        let request: Int
        let generation: Int
        let context: ContextOutcome
    }

    private let held = Mutex<Held?>(nil)

    public init() {}

    /// Holds `context` for `request`'s delivery of `generation`, dropping whatever was held before.
    public func hold(_ context: ContextOutcome, request: Int, generation: Int) {
        held.withLock { $0 = Held(request: request, generation: generation, context: context) }
    }

    /// The context held for exactly this request and generation, or nil.
    public func context(request: Int, generation: Int) -> ContextOutcome? {
        held.withLock { held in
            guard let held, held.request == request, held.generation == generation else { return nil }
            return held.context
        }
    }

    /// `request`'s presentation ended: its context goes. Another request's end leaves it.
    public func end(request: Int) {
        held.withLock { if $0?.request == request { $0 = nil } }
    }

    /// Everything goes: presentation closed.
    public func clear() {
        held.withLock { $0 = nil }
    }

    public var isEmpty: Bool { held.withLock { $0 == nil } }
}

extension CaptureContextSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        held.withLock { held in
            held.map { "CaptureContextSession(request \($0.request), generation \($0.generation), \($0.context))" }
                ?? "CaptureContextSession(empty)"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

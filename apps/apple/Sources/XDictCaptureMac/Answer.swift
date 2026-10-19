import Synchronization

/// **One answer, from whichever side gives first** — a capture racing its deadline, a probe racing its bound. Later gives
/// are ignored; whoever waits is answered once, at once if the answer is already in. Not cancellable by the waiter on
/// purpose: every racer here has a side (a deadline) that always gives.
final class Answer<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiting: [CheckedContinuation<Value, Never>] = []
    }

    private let state = Mutex(State())

    /// True where this was the answer.
    @discardableResult
    func give(_ value: Value) -> Bool {
        let waiting = state.withLock { state -> [CheckedContinuation<Value, Never>]? in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiting = [] }
            return state.waiting
        }
        guard let waiting else { return false }
        for continuation in waiting { continuation.resume(returning: value) }
        return true
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Value? in
                if let value = state.value { return value }
                state.waiting.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

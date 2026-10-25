import Foundation
import XDictAI

/// **One provider call per source kind at a time** (ADR-0021 d.3; plan-ai-meaning WI-5): a second window's ask to the
/// same kind of source waits for the first's, first-in first-out, and a cancelled ask leaves the queue without being
/// asked. The kinds are the settings' own vocabulary — two different HTTP endpoints serialize together, which costs a
/// reader nothing and keeps a machine running two CLIs from doing it at once.
public actor MeaningQueue {
    public static let shared = MeaningQueue()

    private var busy: Set<AIProviderKind> = []
    private var waiters: [Waiter] = []
    /// Cancelled while its continuation was being installed: the wait is resumed with `false` as soon as it is.
    private var cancelled: Set<UUID> = []
    /// Tickets currently inside `acquire`. A cancellation arriving after a ticket has left is ignored, so a completed
    /// ticket never leaves a marker behind. (Audit follow-up, 2026-10-20.)
    private var pending: Set<UUID> = []

    private struct Waiter {
        let kind: AIProviderKind
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// **The asks waiting for a source right now** (audit round 2, 2026-10-25): a test's signal that a second ask is
    /// queued before it is cancelled. Nothing in the app reads it.
    public var waitingCount: Int { waiters.count }

    /// Waits for the source kind and takes it; `false` when the task was cancelled while it waited.
    func acquire(_ kind: AIProviderKind, id: UUID) async -> Bool {
        // **A task already cancelled takes nothing** (audit round 3, 2026-10-25).
        guard !Task.isCancelled else { return false }
        // A ticket is one ask: no marker for it may outlive its acquisition (audit finding, 2026-10-20).
        cancelled.remove(id)
        pending.insert(id)
        if !busy.contains(kind) {
            busy.insert(kind)
            cancelled.remove(id)
            pending.remove(id)
            // The cancellation may have arrived while the source was being taken.
            guard !Task.isCancelled else {
                busy.remove(kind)
                return false
            }
            return true
        }
        let taken = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // The cancellation may already have run, before this continuation existed.
                if cancelled.remove(id) != nil {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(kind: kind, id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        pending.remove(id)
        // A cancellation that raced the hand-over may have inserted a marker after the waiter left; the ticket is done.
        cancelled.remove(id)
        // **A hand-over to a cancelled ask leaves the source free** (audit round 3, 2026-10-25).
        if taken, Task.isCancelled {
            release(kind)
            return false
        }
        return taken
    }

    /// Gives the source kind back: the first waiting ask of that kind takes it, or it goes idle.
    func release(_ kind: AIProviderKind) {
        guard let index = waiters.firstIndex(where: { $0.kind == kind }) else {
            busy.remove(kind)
            return
        }
        // The hand-over keeps `busy`: the first waiter's ask is the one that now holds the kind.
        let waiter = waiters.remove(at: index)
        cancelled.remove(waiter.id)
        waiter.continuation.resume(returning: true)
    }

    private func cancel(_ id: UUID) {
        // The ticket has already acquired or abandoned the wait: a late cancellation changes nothing.
        guard pending.contains(id) else { return }
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            // The cancellation may have raced the continuation's installation; the set holds it until then, and
            // `acquire` removes it when the ticket is done (audit round 3: the old global purge could forget a live marker).
            cancelled.insert(id)
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

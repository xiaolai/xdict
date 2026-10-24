import Foundation

/// **One wait for every suite** (audit, 2026-10-24): seven copies of this loop had drifted in their step and their
/// deadline (5, 10 and 20 ms; 2, 3 and 10 s), and a test that waits four seconds where its neighbour waits two is a
/// suite that fails by host load. A suite adds a new wait here, not a fourth spelling of it.
@MainActor
public func eventually(_ seconds: Double = 2, step: Duration = .milliseconds(5),
                       _ condition: @MainActor () -> Bool) async -> Bool {
    await eventually(for: .seconds(seconds), step: step, condition)
}

/// The same wait with its deadline as a `Duration`, for a suite that keeps one.
@MainActor
public func eventually(for timeout: Duration, step: Duration = .milliseconds(5),
                       _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: step)
    }
    return condition()
}

/// The same wait for a condition that is not main-actor isolated (a child process's exit, a staging folder's state).
public func eventuallyOffMain(_ seconds: Double = 3, step: Duration = .milliseconds(20),
                              _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: step)
    }
    return condition()
}

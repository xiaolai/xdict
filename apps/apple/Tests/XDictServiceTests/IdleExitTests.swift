import Foundation
import Synchronization
import Testing
@testable import XDictService

/// **The idle exit**: after its quiet period with nothing in flight, and never with a request in flight — a request
/// racing the timer either begins first, and the timer only re-arms, or finds the exit decided and is never begun. The
/// E2E `service` stage shows the same of the signed service (`idle.*`); here the clock and the timer are the test's.
struct IdleExitTests {
    /// The test's clock, its timer (the last duration armed) and the exits decided.
    final class Cells: Sendable {
        let clock = Mutex(ContinuousClock.now)
        let armed = Mutex<Duration?>(nil)
        let exits = Mutex<[Duration]>([])
    }

    final class Rig: Sendable {
        let cells = Cells()
        let idle: IdleExit

        init(quiet: Duration = .seconds(30)) {
            let cells = cells
            idle = IdleExit(quiet: quiet, now: { cells.clock.withLock { $0 } },
                            arm: { duration in cells.armed.withLock { $0 = duration } },
                            exit: { quietFor in cells.exits.withLock { $0.append(quietFor) } })
        }

        var armed: Duration? { cells.armed.withLock { $0 } }
        func disarm() { cells.armed.withLock { $0 = nil } }
        var exits: [Duration] { cells.exits.withLock { $0 } }
        func advance(_ by: Duration) { cells.clock.withLock { $0 += by } }
        var exited: Bool { !cells.exits.withLock { $0 }.isEmpty }
    }

    @Test func quietForThePeriodExits() {
        let rig = Rig()
        rig.idle.start()
        #expect(rig.armed == .seconds(30))
        rig.advance(.seconds(30))
        rig.idle.timerFired()
        #expect(rig.exits == [.seconds(30)])
    }

    @Test func aTimerFiringEarlyArmsForWhatIsLeft() {
        let rig = Rig()
        rig.idle.start()
        rig.advance(.seconds(10))
        rig.idle.timerFired()
        #expect(!rig.exited)
        #expect(rig.armed == .seconds(20))
    }

    /// Quiet is measured from the last reply, and nothing exits while a request is in flight, however long.
    @Test func neverWithARequestInFlight() {
        let rig = Rig()
        rig.idle.start()
        #expect(rig.idle.begin())
        rig.advance(.seconds(120))
        rig.idle.timerFired()
        #expect(!rig.exited, "exited with a request in flight")
        rig.disarm()
        rig.idle.end()
        #expect(rig.armed == .seconds(30))
        rig.advance(.seconds(29))
        rig.idle.timerFired()
        #expect(!rig.exited, "exited 29 s after the last reply")
        rig.advance(.seconds(1))
        rig.idle.timerFired()
        #expect(rig.exited)
    }

    /// Once the exit is decided no request begins (in production the process is gone, and its client hears
    /// `interrupted`).
    @Test func aRequestAfterTheDecisionIsNeverBegun() {
        let rig = Rig()
        rig.advance(.seconds(30))
        rig.idle.timerFired()
        #expect(rig.exited)
        #expect(!rig.idle.begin())
    }

    /// **The race, on real threads**: a request arriving while the timer decides, a thousand times. Whichever wins, a
    /// begun request never sees the exit before its end. Red with the in-flight count left out of the decision.
    @Test func aRequestRacingTheTimerGetsExactlyOneFate() async {
        var violations = 0, begun = 0, refused = 0
        for _ in 0..<1_000 {
            let rig = Rig()
            rig.advance(.seconds(30))
            async let fired: Void = Task.detached { rig.idle.timerFired() }.value
            let fate = await Task.detached { () -> Bool? in
                guard rig.idle.begin() else { return nil }
                // Hold the request a moment, as real work does, while the timer may decide.
                for _ in 0..<200 { _ = rig.exited }
                let seen = rig.exited
                rig.idle.end()
                return seen
            }.value
            await fired
            switch fate {
            case .none: refused += 1
            case .some(false): begun += 1
            case .some(true): violations += 1
            }
        }
        #expect(violations == 0, "\(violations) requests saw the exit decided while they were in flight")
        #expect(begun + refused == 1_000 - violations)
    }
}

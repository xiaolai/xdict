import Foundation
import Synchronization
import Testing
import XDictClient
import XDictContract
@testable import XDictService

/// **The idle exit, wired into the service** (plan-verification step 4: the E2E `service.idle` sub-stage moved down a
/// layer): the real listener and `ConnectionSession` in this process, the real `ServiceClient` over NSXPC, and the
/// service's `IdleExit` on the test's clock and timer (`IdleExitTests.Rig`), so a quiet period costs nothing. What
/// `IdleExitTests` shows of `IdleExit` alone, this shows of the session that calls it: a request is in flight from its
/// arrival to its reply, quiet is measured from the last reply, and a request after the decision is never begun. The
/// E2E stage keeps one smoke of the signed service ending itself under launchd (`idle.exitsWhenQuiet`).
@Suite(.serialized)
struct IdleServiceTests {
    static let slow = "slow/slow.mdx"

    /// The service with the rig's idle exit, and a client of it, the dictionary `slow` opened.
    static func service(_ rig: IdleExitTests.Rig) async throws -> (ServiceHarness, ServiceClient, DictId) {
        let harness = try ServiceHarness(idle: rig.idle)
        let fixtures = try ServiceHarness.fixtures()
        let package = DictionaryPackage.of(mdx: fixtures.appending(path: slow),
                                           volumes: [fixtures.appending(path: "slow/slow.mdd")])
        let client = harness.client()
        let dict = try await CreditTests.ready(package, on: client)
        return (harness, client, dict)
    }

    static func lookup(_ dict: DictId) -> ServiceOperation {
        .lookup(query: "slow", dicts: [dict], options: LookupOptions(limit: 10, offset: 0, mode: .reader, generation: nil))
    }

    /// `idle.exitsWhenQuiet`, through the session: every reply re-arms the timer for a whole quiet period, so the exit
    /// comes a quiet period after the **last reply**, not after the first request. Red with `idle.end()` left out of the
    /// reply (`ConnectionSession.answer`): the first request then never leaves flight and nothing ever exits.
    @Test func quietIsMeasuredFromTheLastReply() async throws {
        let rig = IdleExitTests.Rig()
        rig.idle.start()
        let (harness, client, _) = try await Self.service(rig)
        #expect(await client.versions().isSuccess)
        #expect(rig.armed == .seconds(30), "a reply re-arms for the quiet period")
        rig.advance(.seconds(20))
        #expect(await client.versions().isSuccess)
        rig.advance(.seconds(20))
        rig.idle.timerFired()
        #expect(!rig.exited, "exited 20 s after the last reply")
        #expect(rig.armed == .seconds(10), "re-armed for what is left of the quiet period")
        rig.advance(.seconds(10))
        rig.idle.timerFired()
        #expect(rig.exits == [.seconds(30)])
        #expect(harness.context.idle.inFlight == 0)
    }

    /// `idle.workSpanningTheTimer`, through the session: a lookup that has arrived but not yet run (the core's queue held
    /// behind a barrier, so the moment is the test's, not a race) is in flight; the timer firing then, however late, does
    /// not exit, and the lookup is answered. Red with `idle.begin()` left out of `ConnectionSession.receive`.
    @Test func workSpanningTheTimerIsAnswered() async throws {
        let rig = IdleExitTests.Rig()
        rig.idle.start()
        let (harness, client, dict) = try await Self.service(rig)
        let held = DispatchSemaphore(value: 0)
        harness.context.queue.async(flags: .barrier) { held.wait() }
        let answer = Task { await client.call(Self.lookup(dict)) }
        // In the service's lookup gate means past `receive`'s start: queued behind the barrier, not yet run.
        var arrived = false
        for _ in 0..<2_000 where !arrived {
            arrived = harness.context.lookups.load.running > 0
            if !arrived { try await Task.sleep(for: .milliseconds(1)) }
        }
        try #require(arrived, "the lookup never reached the service's gate")
        rig.advance(.seconds(600))
        rig.idle.timerFired()
        let exitedInFlight = rig.exited
        held.signal()
        let outcome = await answer.value
        #expect(!exitedInFlight, "the idle exit was decided with a lookup in flight")
        guard case .success(let delivered) = outcome, case .page = delivered.answer else {
            Issue.record("the spanning lookup was not answered with a page: \(outcome)")
            return
        }
        #expect(harness.context.idle.inFlight == 0)
        #expect(rig.armed == .seconds(30), "the reply re-armed the timer for a whole quiet period")
    }

    /// `idle.racingRequestsAnsweredOnce`, through the session: once the exit is decided, a request that arrives is never
    /// begun — no work, no reply, nothing left in flight (in production the process is gone and the client hears
    /// `interrupted`; here the deadline is all that answers). Before the decision, the same request is answered. Red
    /// with `receive`'s `guard … begin()` turned into a bare call: the late request is then run and answered.
    @Test func aRequestAfterTheDecisionIsNeverBegun() async throws {
        let rig = IdleExitTests.Rig()
        rig.idle.start()
        let (harness, client, _) = try await Self.service(rig)
        #expect(await client.versions().isSuccess, "answered before the decision")
        rig.advance(.seconds(30))
        rig.idle.timerFired()
        try #require(rig.exited)
        let late = ServiceClient(connect: harness.connect, options: ServiceClient.Options(
            deadline: { _, _ in .milliseconds(300) }, importSilence: .seconds(5), retiredGrace: .zero))
        let outcome = await late.versions()
        #expect(outcome == .failure(.wire(.timedOut(deadline: .milliseconds(300)))), "a request after the decision: \(outcome)")
        #expect(harness.context.idle.inFlight == 0)
        #expect(rig.exits.count == 1)
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}

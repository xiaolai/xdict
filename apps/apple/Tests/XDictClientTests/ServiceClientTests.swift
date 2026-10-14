import Foundation
import Testing
import XDictContract
@testable import XDictClient

/// **The client's bookkeeping**, against a fake service: request ids, deadlines, generations per caller, credits.
struct ServiceClientTests {
    @Test func requestIdsIncreaseAndNeverRepeat() async {
        let service = FakeTransport { request, _ in .reply(Fixture.versions, to: request) }
        let client = ServiceClient(connect: service.connect)
        for _ in 0..<3 { _ = await client.versions() }
        service.interruptAll()
        for _ in 0..<2 { _ = await client.versions() }
        #expect(service.sent.map(\.request.id) == [1, 2, 3, 4, 5])
    }

    /// A call's deadline, raised on a connection that has not answered yet: its first call starts the service.
    @Test func aCallPastItsDeadlineAnswersTimedOut() async {
        let first = FakeTransport { _, _ in .silent }
        let cold = ServiceClient(connect: first.connect, options: Fixture.options())
        #expect(await cold.versions() == .failure(.wire(.timedOut(deadline: .milliseconds(600)))))

        let answered = FakeTransport { request, _ in request.id == 1 ? .reply(Fixture.versions, to: request) : .silent }
        let warm = ServiceClient(connect: answered.connect, options: Fixture.options())
        #expect(await warm.versions() == .success(Fixture.versions))
        let started = ContinuousClock.now
        #expect(await warm.versions() == .failure(.wire(.timedOut(deadline: .milliseconds(60)))))
        #expect(ContinuousClock.now - started < .milliseconds(500))
        // A call holding no credit fails alone: the connection is kept.
        #expect(answered.connections.count == 1)
        #expect(answered.connections.allSatisfy { !$0.isInvalidated })
    }

    /// **A superseded call's reply is never delivered**: the call answers `.superseded` at once, and its reply, when it
    /// comes, is discarded. Red with the generation check removed.
    @Test func aSupersededReplyIsNeverDelivered() async {
        let service = FakeTransport { request, _ in
            Fixture.query(request) == "old"
                ? .later(.milliseconds(80), Response(id: request.id, outcome: .answer(Fixture.page())), payload: nil)
                : .reply(Fixture.page(), to: request)
        }
        let log = EventLog()
        let client = ServiceClient(connect: service.connect, watch: log.record)
        let reader = Caller("reader")
        let old = await client.submit(Fixture.lookup("old"), as: reader)
        let new = await client.submit(Fixture.lookup("new"), as: reader, supersedingEarlier: true)
        #expect(await old.outcome(within: .seconds(2)) == .failure(.superseded))
        #expect(await new.outcome(within: .seconds(2)) == .success(Delivered(answer: Fixture.page(), payload: nil)))
        #expect(await log.wait { if case .discarded(old.number, _, _, .superseded) = $0 { true } else { false } })
        #expect(!log.all.contains { if case .answered(old.number, _, _) = $0 { true } else { false } })
    }

    /// **A queued superseded call is never sent**: four lookups take every lookup credit, a fifth waits, and a newer call
    /// of its caller drops it before a credit comes back. Red with the dropping removed.
    @Test func aQueuedSupersededCallIsNeverSent() async {
        let service = FakeTransport { request, _ in
            .later(.milliseconds(60), Response(id: request.id, outcome: .answer(Fixture.page())), payload: nil)
        }
        let log = EventLog()
        let client = ServiceClient(connect: service.connect, watch: log.record)
        var fillers: [CallTicket] = []
        for index in 0..<Limits.lookupCallsInFlight { fillers.append(await client.submit(Fixture.lookup("filler \(index)"))) }
        let reader = Caller("reader")
        let old = await client.submit(Fixture.lookup("old"), as: reader)
        #expect(service.sent.count == Limits.lookupCallsInFlight, "the fifth lookup went without a credit")
        let new = await client.submit(Fixture.lookup("new"), as: reader, supersedingEarlier: true)
        #expect(await old.outcome(within: .seconds(2)) == .failure(.superseded))
        #expect(await new.outcome(within: .seconds(2)) == .success(Delivered(answer: Fixture.page(), payload: nil)))
        for filler in fillers { _ = await filler.outcome(within: .seconds(2)) }
        #expect(!service.sent.contains { Fixture.query($0.request) == "old" }, "the superseded call was sent")
        #expect(log.all.contains(.dropped(call: old.number)))
    }

    /// Credits per class: two bulk calls and four lookups go at once; the rest wait here, in order, and go as replies
    /// come back.
    @Test func callsPastTheirCreditsWaitInTheClient() async {
        let service = FakeTransport { request, _ in
            let answer: Answer = if case .resource(_, let path, _) = request.operation {
                .resource(.missing(path: path))
            } else {
                Fixture.page()
            }
            return .later(.milliseconds(40), Response(id: request.id, outcome: .answer(answer)), payload: nil)
        }
        let client = ServiceClient(connect: service.connect)
        var tickets: [CallTicket] = []
        for index in 0..<3 { tickets.append(await client.submit(Fixture.resource("r\(index)"))) }
        for index in 0..<5 { tickets.append(await client.submit(Fixture.lookup("q\(index)"))) }
        #expect(service.sent.count == Limits.bulkCallsInFlight + Limits.lookupCallsInFlight)
        for ticket in tickets {
            guard case .success = await ticket.outcome(within: .seconds(2)) else {
                Issue.record("call \(ticket.number) did not answer")
                continue
            }
        }
        #expect(service.sent.count == 8)
        let resources = service.sent.compactMap { sent -> String? in
            if case .resource(_, let path, _) = sent.request.operation { return path }
            return nil
        }
        #expect(resources == ["r0", "r1", "r2"])
    }
}

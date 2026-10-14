import Foundation
import XDictClient
import XDictContract

extension ServiceChecks {
    /// **A superseded lookup's late reply is never delivered** (ADR-0009 decision 5). A slow lookup (`big`: the service
    /// reads a 60 MiB record) is sent, then a fast one of the same caller supersedes it while the service still works:
    /// the first is answered `.superseded`, its reply arrives later and is discarded, and only the second is delivered.
    public func supersededReplyIsNeverDelivered() async -> Findings {
        var findings = Findings()
        let log = ClientEventLog()
        let client = makeClient(.contract, log.record)
        guard case .success(let slowDict) = await ready(slow, on: client), case .success(let tinyDict) = await ready(tiny, on: client)
        else { findings.check("supersede.lateReply", false, "the fixtures did not open"); return findings }
        let (took, _) = await timed(.lookup(query: "big", dicts: [slowDict], options: Self.firstPage), on: client)
        findings.fact("supersede.slowLookupMilliseconds", milliseconds(took))

        let caller = Caller("search field")
        let first = await client.submit(.lookup(query: "big", dicts: [slowDict], options: Self.firstPage), as: caller,
                                        supersedingEarlier: true)
        let second = await client.submit(.lookup(query: "run", dicts: [tinyDict], options: Self.firstPage), as: caller,
                                         supersedingEarlier: true)
        let delivered = await second.outcome()
        let superseded = await first.outcome()
        let replied = await log.wait(.seconds(10)) { event in
            if case .discarded(first.number, _, _, _) = event { return true }
            if case .answered(first.number, _, _) = event { return true }
            return false
        }
        let sent = log.all.contains { if case .sent(first.number, _, _) = $0 { true } else { false } }
        let discarded = log.all.contains { if case .discarded(first.number, _, _, .superseded) = $0 { true } else { false } }
        let answered = log.all.contains { if case .answered(first.number, _, _) = $0 { true } else { false } }
        var secondTotal: UInt64?
        if case .success(let d) = delivered, case .page(let page) = d.answer { secondTotal = page.total }
        findings.check("supersede.lateReply",
                       superseded == .failure(.superseded) && sent && replied && discarded && !answered && secondTotal == 3,
                       "first: \(superseded), sent \(sent), its reply came \(replied), discarded as superseded \(discarded), "
                       + "delivered \(answered); second's total \(secondTotal.map(String.init) ?? "none")")
        return findings
    }

    /// **A queued superseded request is never sent.** Four slow lookups take every lookup credit of the connection, so a
    /// fifth waits in the client; its caller's next call supersedes it there, and it is dropped — no `sent` for it, ever
    /// — while the next is sent once a credit comes back, and answered.
    public func queuedSupersededIsNeverSent() async -> Findings {
        var findings = Findings()
        let log = ClientEventLog()
        let client = makeClient(.contract, log.record)
        guard case .success(let slowDict) = await ready(slow, on: client), case .success(let tinyDict) = await ready(tiny, on: client)
        else { findings.check("supersede.queuedNeverSent", false, "the fixtures did not open"); return findings }
        var blockers: [CallTicket] = []
        for _ in 0..<Limits.lookupCallsInFlight {
            blockers.append(await client.submit(.lookup(query: "big", dicts: [slowDict], options: Self.firstPage)))
        }
        let caller = Caller("results list")
        let queued = await client.submit(.lookup(query: "run", dicts: [tinyDict], options: Self.firstPage), as: caller)
        let next = await client.submit(.lookup(query: "cafe", dicts: [tinyDict], options: Self.firstPage), as: caller,
                                       supersedingEarlier: true)
        let dropped = await queued.outcome()
        let answered = await next.outcome()
        for blocker in blockers { _ = await blocker.outcome() }
        let events = log.all
        let wasSent = events.contains { if case .sent(queued.number, _, _) = $0 { true } else { false } }
        let wasDropped = events.contains { if case .dropped(queued.number) = $0 { true } else { false } }
        let blockersSentFirst = blockers.allSatisfy { blocker in
            events.contains { if case .sent(blocker.number, _, _) = $0 { true } else { false } }
        }
        var nextTotal: UInt64?
        if case .success(let d) = answered, case .page(let page) = d.answer { nextTotal = page.total }
        findings.check("supersede.queuedNeverSent",
                       dropped == .failure(.superseded) && wasDropped && !wasSent && blockersSentFirst && nextTotal == 1,
                       "queued: \(dropped), dropped \(wasDropped), sent \(wasSent); the four ahead sent \(blockersSentFirst); "
                       + "next's total \(nextTotal.map(String.init) ?? "none")")
        return findings
    }
}

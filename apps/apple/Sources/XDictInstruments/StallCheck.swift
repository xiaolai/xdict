import Foundation
import XDictClient
import XDictContract

extension ServiceChecks {
    /// The deadline the stall check gives a resource on a warm connection: far below what reading `big.bin` takes.
    static let stalledDeadline: Duration = .milliseconds(25)

    /// **A bulk call past its deadline frees the client by a new connection** (ADR-0009 decision 4, refutation 11). Two
    /// resources of 63 MiB take both bulk credits under a deadline they cannot meet; a third waits in the client. When
    /// the deadline passes, the two answer `timedOut`, the connection is abandoned, and the third goes on a new
    /// connection with every credit — answered while the stalled two still run in the service, which the order of
    /// events shows: its answer before either stalled reply comes back (and is discarded as late). The service's own
    /// ceiling (`WorkGate`, two connections' credits) is what lets it run beside them.
    public func stalledBulkFreesTheClient() async -> Findings {
        var findings = Findings()
        // A plain client first: how long the read really takes, warm.
        let plain = makeClient(.contract, nil)
        guard case .success(let measured) = await ready(slow, on: plain) else {
            findings.check("stall.newConnection", false, "slow did not open")
            return findings
        }
        let (took, baseline) = await timed(.resource(dict: measured, path: "big.bin", render: .reader), on: plain, runs: 2)
        findings.fact("stall.bigResourceMilliseconds", milliseconds(took))
        guard case .success(let d) = baseline, case .resource(.found) = d.answer, d.payload?.count == 63 << 20 else {
            findings.check("stall.newConnection", false, "big.bin did not come back whole: \(baseline)")
            return findings
        }

        let log = ClientEventLog()
        var options = ServiceClient.Options.contract
        options.deadline = { operation, fresh in
            if case .resource = operation, !fresh { return Self.stalledDeadline }
            return Deadlines.deadline(for: operation, onFreshConnection: fresh)
        }
        let client = makeClient(options, log.record)
        guard case .success(let dict) = await ready(slow, on: client), case .success = await client.versions() else {
            findings.check("stall.newConnection", false, "slow did not open on the stalling client")
            return findings
        }
        let big = ServiceOperation.resource(dict: dict, path: "big.bin", render: .reader)
        let stalled = [await client.submit(big), await client.submit(big)]
        let third = await client.submit(.resource(dict: dict, path: "small.bin", render: .reader))
        var stalledOutcomes: [ClientOutcome] = []
        for ticket in stalled { stalledOutcomes.append(await ticket.outcome()) }
        let thirdOutcome = await third.outcome()
        let lateCame = await Self.waitUntil(.seconds(20)) {
            stalled.allSatisfy { ticket in
                log.first { if case .discarded(ticket.number, _, _, .late) = $0 { true } else { false } } != nil
            }
        }
        let events = log.all
        func link(of call: UInt64) -> Int? {
            events.first { if case .sent(call, _, _) = $0 { true } else { false } }?.link
        }
        let thirdAnswered = log.index { if case .answered(third.number, _, _) = $0 { true } else { false } }
        let lateReplies = stalled.compactMap { ticket in
            log.index { if case .discarded(ticket.number, _, _, .late) = $0 { true } else { false } }
        }
        let timedOut = stalledOutcomes.allSatisfy { $0 == .failure(.wire(.timedOut(deadline: Self.stalledDeadline))) }
        let abandoned = events.contains { if case .abandoned(let l) = $0 { l == link(of: stalled[0].number) } else { false } }
        var thirdWhole = false
        if case .success(let d) = thirdOutcome, d.payload == Data("small".utf8) { thirdWhole = true }
        let newConnection = link(of: third.number).map { $0 != link(of: stalled[0].number) } ?? false
        let beforeTheStalled = thirdAnswered.map { answered in lateReplies.count == 2 && lateReplies.allSatisfy { answered < $0 } }
            ?? false
        findings.check("stall.timedOut", timedOut, "\(stalledOutcomes)")
        findings.check("stall.newConnection", abandoned && newConnection && thirdWhole,
                       "abandoned \(abandoned); third on link \(link(of: third.number).map(String.init) ?? "none") after "
                       + "link \(link(of: stalled[0].number).map(String.init) ?? "none"); answered whole \(thirdWhole)")
        findings.check("stall.answeredWhileTheStalledRun", beforeTheStalled && lateCame,
                       "third answered at event \(thirdAnswered.map(String.init) ?? "none"), the stalled replies came back "
                       + "late at \(lateReplies)")
        return findings
    }
}

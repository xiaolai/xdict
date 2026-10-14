import Foundation
import XDictClient
import XDictContract

extension ServiceChecks {
    /// The quiet periods consistent with the service's 30 s (`IdleExit.quietPeriod`), measured from the client: its last
    /// reply to its interruption.
    static let acceptedQuiet: ClosedRange<Duration> = .seconds(29) ... .seconds(35)
    /// How far apart two racing requests may be and still bracket the moment the service decides; and the most trials
    /// the race may take to find it (each is a quiet period, 30 s).
    static let raceStep: Duration = .milliseconds(1)
    static let raceTrials = 8
    /// How late a timed request may leave and still be aimed where it was meant: the race's step. A request that leaves
    /// later races nothing; on 2026-10-14 the instrument's sleeps, coalesced, woke 1.5 s late and every "race" was a
    /// relaunch, which passed.
    static let onTime: Duration = .milliseconds(1)

    /// Waits until `target` and answers how late it got there: asleep until 5 ms before, on a timer that is not coalesced,
    /// then spinning, because even that timer woke 1.5–2 ms late on the E2E Mac (2026-10-14), later than the race's step.
    static func wake(at target: ContinuousClock.Instant) async -> Duration {
        try? await Task.sleep(until: target - .milliseconds(5), tolerance: .zero, clock: .continuous)
        while ContinuousClock.now < target {}
        return ContinuousClock.now - target
    }

    /// **The idle exit never fires with work in flight, and a request racing it gets exactly one outcome** (ADR-0009
    /// decision 4, refutation 12). Against the real service and its real timer, two to five minutes:
    /// 1. quiet: the service ends itself after its quiet period with nothing in flight, measured from the last reply to
    ///    the connection's interruption; a request then starts it again (the relaunch, measured);
    /// 2. span: a slow lookup sent half its length before the timer's moment is answered by the same process;
    /// 3. race: requests aimed at the timer's moment, one per quiet period, each answered or `interrupted` — never lost
    ///    to a deadline, never anything else — until one is interrupted, or two a step apart fall either side of it.
    /// **A request that left late is a failure of its check**, not a pass: aimed at the timer and sent after it, it shows
    /// only a relaunch (`onTime`). The caller holds the process out of timer coalescing (`ServiceReport`).
    /// **Ends the service's process**: never run it against a listener in the caller's own process.
    public func idleExitRaced() async -> Findings {
        var findings = Findings()
        let log = ClientEventLog()
        let client = makeClient(.contract, log.record)
        guard case .success(let slowDict) = await ready(slow, on: client) else {
            findings.check("idle.exitsWhenQuiet", false, "slow did not open")
            return findings
        }
        let big = ServiceOperation.lookup(query: "big", dicts: [slowDict], options: Self.firstPage)
        let (took, _) = await timed(big, on: client)

        // 1. Quiet.
        _ = await client.call(.versions)
        let quietFrom = ContinuousClock.now
        let interrupted: @Sendable (ClientEvent) -> Bool = { if case .interrupted = $0 { true } else { false } }
        let exited = await log.wait(.seconds(60), for: interrupted)
        let quiet = (log.first(interrupted) ?? quietFrom) - quietFrom
        findings.fact("idle.quietMilliseconds", milliseconds(quiet))
        findings.check("idle.exitsWhenQuiet", exited && Self.acceptedQuiet.contains(quiet),
                       "the service \(exited ? "exited" : "did not exit") \(quiet) after the last reply, nothing in flight")
        guard exited else { return findings }
        let relaunchFrom = ContinuousClock.now
        let relaunched = await client.call(.versions)
        findings.fact("idle.relaunchMilliseconds", milliseconds(ContinuousClock.now - relaunchFrom))
        var reference = ContinuousClock.now
        if case .failure(let why) = relaunched { findings.fact("idle.relaunch", "\(why)") }

        // 2. Work spanning the timer.
        let lead = max(took / 2, .milliseconds(5))
        let pid = await client.servicePID
        let interruptionsBefore = log.all.filter(interrupted).count
        let spanLate = await Self.wake(at: reference + quiet - lead)
        let spanning = await client.call(big)
        reference = ContinuousClock.now
        let stayed = await client.servicePID == pid && log.all.filter(interrupted).count == interruptionsBefore
        var spanned = false
        if case .success(let d) = spanning, case .page = d.answer { spanned = true }
        findings.check("idle.workSpanningTheTimer", spanned && stayed && spanLate <= Self.onTime,
                       "a \(took) lookup aimed \(lead) before the timer, sent \(spanLate) late: "
                       + "\(spanned ? "answered" : "\(spanning)"), the same process \(stayed)")

        // 3. Requests racing the timer, each its own trial a quiet period after the last reply. **They must find the
        // exit**: the client's aim is off by a few milliseconds (it learns of an exit late), so a fixed window can miss
        // it, and a race that missed passes vacuously (2026-10-14). So the aim moves a step later after a trial the same
        // process answered (it beat the timer) and a step earlier after one that found the service ended (`interrupted`,
        // or a new process answered), until a trial is interrupted or two a step apart bracket the exit.
        var outcomes: [String] = []
        var exactlyOnce = true
        var allOnTime = true
        var offset = Duration.zero
        var beat: Duration?  // the latest aim the same process answered
        var ended: Duration?  // the earliest aim that found it ended
        var interruptedOnce = false
        func found() -> Bool {
            if interruptedOnce { return true }
            guard let beat, let ended else { return false }
            return ended > beat && ended - beat <= Self.raceStep
        }
        for _ in 0..<Self.raceTrials where !found() && exactlyOnce {
            let before = await client.servicePID
            let interruptions = log.all.filter(interrupted).count
            let late = await Self.wake(at: reference + quiet + offset)
            allOnTime = allOnTime && late <= Self.onTime
            let raced = await client.call(.versions)
            let sameProcess = await client.servicePID == before && log.all.filter(interrupted).count == interruptions
            let aim = "\(offset) (sent \(late) late)"
            switch raced {
            case .success where sameProcess:
                outcomes.append("\(aim): answered by the same process")
                beat = max(beat ?? offset, offset)
                offset += Self.raceStep
            case .success:
                outcomes.append("\(aim): answered by a new process")
                ended = min(ended ?? offset, offset)
                offset -= Self.raceStep
            case .failure(.wire(.interrupted)):
                outcomes.append("\(aim): interrupted")
                interruptedOnce = true
                _ = await client.call(.versions)
            case .failure(let other):
                outcomes.append("\(aim): \(other)")
                exactlyOnce = false
            }
            reference = ContinuousClock.now
        }
        let raced = found()
        findings.fact("idle.raced", outcomes.joined(separator: "; "))
        findings.check("idle.racingRequestsAnsweredOnce", exactlyOnce && allOnTime && raced,
                       outcomes.joined(separator: "; ")
                       + (raced ? "" : "; \(outcomes.count) trials never found the exit within \(Self.raceStep)"))
        return findings
    }
}

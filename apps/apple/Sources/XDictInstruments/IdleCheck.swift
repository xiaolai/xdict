import Foundation
import XDictClient
import XDictContract

extension ServiceChecks {
    /// The quiet periods consistent with the service's 30 s (`IdleExit.quietPeriod`), measured from the client: its last
    /// reply to its interruption.
    static let acceptedQuiet: ClosedRange<Duration> = .seconds(29) ... .seconds(35)
    /// **The signed service ends itself under launchd after its quiet period, and launchd starts it again** (ADR-0009
    /// decision 4): the one smoke of the idle exit kept end to end (plan-verification §4.1). Against the real service and
    /// its real timer, about 35 s: the service ends after its quiet period with nothing in flight, measured from the last
    /// reply to the connection's interruption, and a request then starts it again (the relaunch, measured). That a request
    /// is in flight from arrival to reply, that quiet is measured from the last reply, and that a request after the
    /// decision is never begun are `IdleServiceTests` (the service in-process, on the test's clock) and `IdleExitTests`.
    /// **Ends the service's process**: never run it against a listener in the caller's own process.
    public func idleExitUnderLaunchd() async -> Findings {
        var findings = Findings()
        let log = ClientEventLog()
        let client = makeClient(.contract, log.record)
        // 1. Quiet.
        _ = await client.call(.versions)
        let quietFrom = ContinuousClock.now
        let interrupted: @Sendable (ClientEvent) -> Bool = { if case .interrupted = $0 { true } else { false } }
        let exited = await log.wait(.seconds(60), for: interrupted)
        let quiet = (log.first(interrupted) ?? quietFrom) - quietFrom
        findings.fact("idle.quietMilliseconds", milliseconds(quiet))
        guard exited else {
            findings.check("idle.exitsWhenQuiet", false, "the service did not exit \(quiet) after the last reply")
            return findings
        }
        // 2. Started again: the next request is answered.
        let relaunchFrom = ContinuousClock.now
        let relaunched = await client.call(.versions)
        findings.fact("idle.relaunchMilliseconds", milliseconds(ContinuousClock.now - relaunchFrom))
        var answered = false
        if case .success = relaunched { answered = true }
        findings.check("idle.exitsWhenQuiet", Self.acceptedQuiet.contains(quiet) && answered,
                       "the service exited \(quiet) after the last reply, nothing in flight; the next request: "
                       + (answered ? "answered" : "\(relaunched)"))
        return findings
    }
}

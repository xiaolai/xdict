import Foundation
import XDictClient
import XDictContract

extension ServiceChecks {
    /// **`kill -9` of the service mid-lookup gives a typed error, and the next lookup succeeds.** A lookup that reads a
    /// 60 MiB record is sent; a quarter of the way through its measured time the service is killed. The lookup must answer
    /// `interrupted`; the next lookup, by the handle the caller already holds, must be answered by a new service process,
    /// the client having opened the dictionary again (`staleHandle` → `open`). **Ends the service's process**: never run it
    /// against a listener in the caller's own process.
    public func killMidLookup() async -> Findings {
        var findings = Findings()
        let log = ClientEventLog()
        let client = makeClient(.contract, log.record)
        guard case .success(let slowDict) = await ready(slow, on: client),
              case .success(let tinyDict) = await ready(tiny, on: client) else {
            findings.check("kill.typedError", false, "the fixtures did not open")
            return findings
        }
        let big = ServiceOperation.lookup(query: "big", dicts: [slowDict], options: Self.firstPage)
        let (took, _) = await timed(big, on: client)
        findings.fact("kill.slowLookupMilliseconds", milliseconds(took))
        let before = await client.servicePID
        guard before > 0, before != getpid() else {
            findings.check("kill.typedError", false, "no service process to kill (pid \(before))")
            return findings
        }
        let lookup = await client.submit(big)
        try? await Task.sleep(for: max(.milliseconds(2), took / 4))
        let killed = kill(before, SIGKILL) == 0
        let outcome = await lookup.outcome()
        findings.check("kill.typedError", killed && outcome == .failure(.wire(.interrupted)),
                       "killed pid \(before) \(took / 4) into a \(took) lookup (\(killed)); the lookup answered \(outcome)")

        let next = await client.call(.lookup(query: "run", dicts: [tinyDict], options: Self.firstPage))
        let after = await client.servicePID
        var total: UInt64?, dicts: Set<DictId> = []
        if case .success(let d) = next, case .page(let page) = d.answer {
            total = page.total
            dicts = Set(page.hits.map(\.dict))
        }
        let reopened = log.all.contains { if case .reopened(tinyDict, _) = $0 { true } else { false } }
        findings.check("kill.nextLookupSucceeds", total == 3 && dicts == [tinyDict] && after > 0 && after != before && reopened,
                       "next: total \(total.map(String.init) ?? "none") under the caller's handle \(dicts == [tinyDict]); "
                       + "service pid \(before) → \(after); reopened \(reopened)")
        return findings
    }
}

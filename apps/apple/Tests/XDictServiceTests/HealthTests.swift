import Foundation
import Synchronization
import Testing
import XDictClient
import XDictContract

/// **The health check through the real service** (plan-macos-v1 WI-12; contract 3): the core's findings for an open
/// dictionary, reported with progress, and kept, so a second ask answers the same at once.
struct HealthTests {
    @Test func theServiceChecksAnOpenDictionaryAndKeepsTheReport() async throws {
        let harness = try ServiceHarness()
        let dir = try ServiceHarness.fixtures().appending(path: "tiny")
        try #require(FileManager.default.fileExists(atPath: dir.appending(path: "tiny.mdx").path),
                     "no tiny fixture: run `make test`, or Tools/build-fixtures.sh .build/fixtures")
        let client = harness.client()
        let package = DictionaryPackage.of(mdx: dir.appending(path: "tiny.mdx"), volumes: [dir.appending(path: "tiny.mdd")],
                                           sidecars: [dir.appending(path: "tiny.css")])
        guard case .success = await client.importPackage(package),
              case .success(.ready(let dict, _, _)) = await client.open(package) else {
            Issue.record("the tiny fixture did not import and open")
            return
        }
        let reports = Mutex<[UInt64]>([])
        let first = await client.submitHealth(dict) { done, _ in reports.withLock { $0.append(done) } }.outcome()
        guard case .success(let delivered) = first, case .health(let health) = delivered.answer else {
            Issue.record("no health report: \(first)")
            return
        }
        #expect(health.entries == 8)
        #expect(health.findings.map(\.kind) == [.brokenRedirects])
        #expect(health.findings.first?.examples.first?.key == "lost")
        // At most one progress report, after the one chunk. Not exactly one: the reply comes back through the call's reply
        // block and a report as a message to the client's exported object, two deliveries NSXPC does not order between
        // them, and the client drops a report for a call already answered. The full service target lost it 3 runs in 10
        // (2026-10-18), and still 1 in 20 with the client taking its callbacks in arrival order.
        let heard = reports.withLock { $0 }
        #expect(heard == [8] || heard.isEmpty, "one progress report at most, after the one chunk: \(heard)")
        let again = await client.submitHealth(dict).outcome()
        guard case .success(let second) = again, case .health(let kept) = second.answer else {
            Issue.record("no second report: \(again)")
            return
        }
        #expect(kept == health)
    }
}

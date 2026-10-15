import Foundation
import Testing
import XDictClient
import XDictInstruments

/// **The main window's search through the real service** (plan-macos-v1 WI-6, done-when with generated dictionaries):
/// the E2E `lookup` stage's scenario, run here with no window against the service's own listener over a real NSXPC
/// connection, with the core reading `Tools/build-fixtures.sh`'s `lookup/` dictionaries. Every check the stage requires
/// of the scenario (all but LDOCE's, which needs the owner's dictionaries) must be reported, and pass.
@MainActor
struct LookupScenarioTests {
    @Test func theLookupScenarioPassesThroughTheService() async throws {
        let harness = try ServiceHarness()
        let fixtures = try ServiceHarness.fixtures().appending(path: "lookup")
        try #require(FileManager.default.fileExists(atPath: fixtures.appending(path: "records/records.mdx").path),
                     "no lookup fixtures: run `make test`, or Tools/build-fixtures.sh .build/fixtures")
        let scratch = try ServiceHarness.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let hold = TransportHold()
        let client = ServiceClient(connect: hold.connect(harness.connect))
        let findings = await LookupScenario.headless(client: client, hold: hold, fixtures: fixtures, scratch: scratch)
        LibraryScenarioTests.print(findings)
        let reported = Set(findings.checks.map(\.name))
        #expect(reported.isSuperset(of: LookupScenario.checkNames),
                "never reported: \(LookupScenario.checkNames.subtracting(reported).sorted())")
        #expect(findings.failed.isEmpty, "\(findings.failed.map { "\($0.name): \($0.detail)" })")
    }
}

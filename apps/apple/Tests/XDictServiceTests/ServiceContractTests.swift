import Foundation
import Testing
import XDictClient
import XDictContract
import XDictCore
import XDictInstruments
@testable import XDictService

/// **The service's half of the contract, asked as the app asks it**: the real listener in this process, the real client,
/// and the very scenarios the E2E `service` stage runs against the signed service — all but the two that end the
/// service's process (the kill and the idle exit), which would end this one.
@Suite(.serialized)
struct ServiceContractTests {
    static func record(_ findings: Findings) {
        for check in findings.checks where !check.pass { Issue.record("\(check.name): \(check.detail)") }
        #expect(!findings.checks.isEmpty, "the scenario checked nothing")
    }

    /// The versions the service answers are the binding's, and those `Generated/core-versions.json` records — what the
    /// bundle ships and the E2E `launch` stage compares the handshake with.
    @Test func theServiceAnswersWithTheCoresVersions() async throws {
        let harness = try ServiceHarness()
        let core = XDictCore.versions()
        #expect(await harness.client().versions() == .success(XDictContract.Versions(core)))
        let recorded = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Generated/core-versions.json")
        let decoded = try JSONDecoder().decode(XDictContract.Versions.self, from: Data(contentsOf: recorded))
        #expect(decoded == XDictContract.Versions(core))
    }

    /// `conformance/`'s `tiny` and `matrix` answer as `expected.json` says, through the contract.
    @Test func theConformanceFixturesAnswerThroughTheContract() async throws {
        let harness = try ServiceHarness()
        let scratch = try ServiceHarness.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let findings = await ConformanceScenario(client: harness.client(), fixtures: try ServiceHarness.fixtures(),
                                                 scratch: scratch).run()
        Self.record(findings)
        #expect(findings.checks.map(\.name) == ["conformance.tiny", "conformance.matrix"])
    }

    /// Runs `scenario` against the harness's service in a scratch directory of its own, removed afterwards.
    static func run(_ scenario: (ServiceChecks) async -> Findings) async throws -> Findings {
        let harness = try ServiceHarness()
        let scratch = try ServiceHarness.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let checks = ServiceChecks(fixtures: try ServiceHarness.fixtures(), scratch: scratch) { options, watch in
            harness.client(options, watch: watch)
        }
        return await scenario(checks)
    }

    @Test func whatIsNotADictionaryFileIsRefused() async throws {
        let findings = try await Self.run { await $0.refusals() }
        Self.record(findings)
        #expect(findings.checks.count == 6)
    }

    @Test func aSupersededReplyIsNeverDelivered() async throws {
        Self.record(try await Self.run { await $0.supersededReplyIsNeverDelivered() })
    }

    @Test func aQueuedSupersededRequestIsNeverSent() async throws {
        Self.record(try await Self.run { await $0.queuedSupersededIsNeverSent() })
    }

    @Test func aStalledBulkCallFreesTheClient() async throws {
        Self.record(try await Self.run { await $0.stalledBulkFreesTheClient() })
    }
}

import Foundation
import Testing
import XDictInstruments

/// **The library through the real service** (plan-macos-v1 WI-5, done-when with generated packages): the E2E `library`
/// stage's scenario, run here against the service's own listener over a real NSXPC connection, with the core reading
/// `Tools/build-fixtures.sh`'s library packages. Every check the stage requires must be reported, and pass.
@MainActor
struct LibraryScenarioTests {
    @Test func theLibraryScenarioPassesThroughTheService() async throws {
        let harness = try ServiceHarness()
        let fixtures = try ServiceHarness.fixtures()
        let scratch = try ServiceHarness.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        // A scratch folder not there yet, as the app passes it (`--library-report`).
        let findings = await LibraryScenario(client: harness.client(), fixtures: fixtures,
                                             scratch: scratch.appending(path: "not-there-yet")).run()
        Self.print(findings)
        let reported = Set(findings.checks.map(\.name))
        #expect(reported.isSuperset(of: LibraryScenario.checkNames),
                "never reported: \(LibraryScenario.checkNames.subtracting(reported).sorted())")
        #expect(findings.failed.isEmpty, "\(findings.failed.map { "\($0.name): \($0.detail)" })")
    }

    /// The owner's-dictionaries instrument (`--library-corpus`) on generated ones, in its three launches as the E2E
    /// stage runs them: imported against editions `shasum` computes, moved to a place named through a link (as the
    /// stage's `/tmp` is), relaunched, and one rewritten.
    @Test func theCorpusInstrumentPassesOnGeneratedDictionaries() async throws {
        let harness = try ServiceHarness()
        let fixtures = try ServiceHarness.fixtures()
        let scratch = try ServiceHarness.scratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let corpus = scratch.appending(path: "corpus-a")
        var expected: [String: String] = [:]
        for (folder, file) in [("single", "file/single.mdx"), ("plain", "lang/Plain Glossary.mdx")] {
            let mdx = fixtures.appending(path: "library/\(file)")
            try FileManager.default.createDirectory(at: corpus.appending(path: folder), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: mdx, to: corpus.appending(path: "\(folder)/\(mdx.lastPathComponent)"))
            expected[folder] = "mdx-sha256-v1:" + (try Self.sha256(mdx))
        }
        let link = scratch.appending(path: "through-a-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: scratch)
        let instrument = LibraryCorpus(client: harness.client(), libraryDirectory: scratch.appending(path: "library"))

        var findings = await instrument.importing(corpus, expected: expected)
        try FileManager.default.moveItem(at: corpus, to: scratch.appending(path: "corpus-b"))
        findings.merge(await instrument.relaunch(movedTo: link.appending(path: "corpus-b"), relinking: true))
        findings.merge(await instrument.rewrite())
        Self.print(findings)
        let reported = Set(findings.checks.map(\.name))
        #expect(reported.isSuperset(of: ["corpus.registered", "corpus.editions", "relaunch.everyDictionary",
                                         "relaunch.foundWhereMoved", "relaunch.answering", "corpus.changed.undone"]))
        #expect(findings.failed.isEmpty, "\(findings.failed.map { "\($0.name): \($0.detail)" })")
    }

    static func sha256(_ file: URL) throws -> String {
        let shasum = Process(), output = Pipe()
        shasum.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        shasum.arguments = ["-a", "256", file.path]
        shasum.standardOutput = output
        try shasum.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        shasum.waitUntilExit()
        let hex = try #require(text.split(separator: " ").first.map(String.init))
        try #require(shasum.terminationStatus == 0 && hex.count == 64, "shasum said \(text)")
        return hex
    }

    static func print(_ findings: Findings) {
        guard ProcessInfo.processInfo.environment["XDICT_PRINT_FINDINGS"] != nil else { return }
        for check in findings.checks { Swift.print("CHECK \(check.pass) \(check.name): \(check.detail.prefix(220))") }
    }
}

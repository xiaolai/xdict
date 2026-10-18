import Foundation
import Testing
import XDictClient
import XDictContract

/// **A dictionary's display options through the real service** (ADR-0013 decisions 2 and 6; contract 7): the service
/// asks the core, which reads the edition's markup; the app only receives the answer. The dictionaries are the tiny
/// fixture's `displayOptions` files, written by the test suite's own MDX writer (`conformance/fixtures/tiny`).
struct DisplayOptionsServiceTests {
    static func opened(_ client: ServiceClient, mdx: String, sidecars: [String]) async throws -> DictId? {
        let dir = try ServiceHarness.fixtures().appending(path: "tiny")
        try #require(FileManager.default.fileExists(atPath: dir.appending(path: mdx).path),
                     "no \(mdx): run `make test`, or Tools/build-fixtures.sh .build/fixtures")
        let package = DictionaryPackage.of(mdx: dir.appending(path: mdx), volumes: [],
                                           sidecars: sidecars.map { dir.appending(path: $0) })
        guard case .success = await client.importPackage(package),
              case .success(.ready(let dict, _, _)) = await client.open(package) else { return nil }
        return dict
    }

    /// NOAD's markup and sheet: pronunciation applies, IPA by default, with the core's CSS keyed on the root attribute.
    @Test func theServiceAnswersTheOptionsAnEditionDeclares() async throws {
        let harness = try ServiceHarness()
        let client = harness.client()
        let dict = try #require(try await Self.opened(client, mdx: "prn.mdx", sidecars: ["prn-noad.css"]),
                                "prn.mdx did not import and open")
        let outcome = await client.call(.displayOptions(dict: dict))
        guard case .success(let delivered) = outcome, case .displayOptions(let options) = delivered.answer else {
            Issue.record("no display options: \(outcome)")
            return
        }
        #expect(options.version > 0)
        #expect(options.options == [DisplayOption(id: "pronunciation", attribute: "data-xdict-opt-pronunciation",
                                                  values: ["respell", "ipa", "both"], defaultValue: "ipa")])
        #expect(options.css.contains(#":root[data-xdict-opt-pronunciation="respell"]"#), "\(options.css)")
        #expect(delivered.payload == nil)
    }

    /// A dictionary whose markup carries one variant only declares nothing: an empty answer, not a failure.
    @Test func aDictionaryWithoutTheContractDeclaresNothing() async throws {
        let harness = try ServiceHarness()
        let client = harness.client()
        let dict = try #require(try await Self.opened(client, mdx: "prn-one.mdx", sidecars: ["prn-noad.css"]),
                                "prn-one.mdx did not import and open")
        let outcome = await client.call(.displayOptions(dict: dict))
        guard case .success(let delivered) = outcome, case .displayOptions(let options) = delivered.answer else {
            Issue.record("no display options: \(outcome)")
            return
        }
        #expect(options.options.isEmpty && options.css.isEmpty)
    }
}

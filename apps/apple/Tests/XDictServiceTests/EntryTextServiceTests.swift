import Foundation
import Testing
import XDictClient
import XDictContract

/// **`entry_text` through the real service** (contract 8; ADR-0021 d.5): the core projects the same entry the entry view
/// renders into plain text, with spans and a cut report, and the app only receives it. The fixture is `tiny`, whose entry
/// `run` (occurrence 0) carries text, a stylesheet link and a sound control (`conformance/fixtures/tiny/expected.json`).
struct EntryTextServiceTests {
    static func opened() async throws -> (ServiceHarness, ServiceClient, DictId, EntryRef)? {
        let harness = try ServiceHarness()
        let dir = try ServiceHarness.fixtures().appending(path: "tiny")
        try #require(FileManager.default.fileExists(atPath: dir.appending(path: "tiny.mdx").path),
                     "no tiny fixture: run `make test`, or Tools/build-fixtures.sh .build/fixtures")
        let client = harness.client()
        let package = DictionaryPackage.of(mdx: dir.appending(path: "tiny.mdx"), volumes: [], sidecars: [])
        guard case .success(let imported) = await client.importPackage(package),
              case .success(.ready(let dict, _, _)) = await client.open(package) else {
            Issue.record("the tiny fixture did not import and open")
            return nil
        }
        return (harness, client, dict, EntryRef(edition: imported.edition, key: "run", occurrence: 0))
    }

    @Test func theWholeEntryComesBackAsTextWithSpans() async throws {
        let opened = try #require(try await Self.opened())
        let (_, client, dict, ref) = opened
        let text = TextRenderContext(maxBodyBytes: 1 << 20, maxTextBytes: 1 << 20)
        let outcome = await client.call(.entryText(dict: dict, entry: ref, text: text))
        guard case .success(let delivered) = outcome, case .entryText(let projected) = delivered.answer else {
            Issue.record("no entry text: \(outcome)")
            return
        }
        #expect(delivered.payload == nil)
        #expect(projected.entry == ref)
        #expect(projected.complete, "a 1 MiB budget leaves this fixture's entry whole")
        #expect(projected.omittedBytes == 0 && projected.spansDropped == 0)
        #expect(projected.cutAt == UInt64(projected.text.utf8.count))
        #expect(!projected.text.isEmpty)
        #expect(projected.text.contains("to move fast"), "the entry's own words are the text")
        #expect(!projected.text.contains("xdict://d/"), "a link is not text")
        // Spans lie inside the text, in UTF-8 bytes, as the core reported them.
        let bytes = UInt64(projected.text.utf8.count)
        for span in projected.spans {
            #expect(span.start <= bytes && span.len <= bytes - span.start, "a span outside its text: \(span)")
        }
    }

    @Test func aBudgetCutsTheTextWithItsReportRatherThanFailing() async throws {
        let opened = try #require(try await Self.opened())
        let (_, client, dict, ref) = opened
        let text = TextRenderContext(maxBodyBytes: 1 << 20, maxTextBytes: 8)
        let outcome = await client.call(.entryText(dict: dict, entry: ref, text: text))
        guard case .success(let delivered) = outcome, case .entryText(let projected) = delivered.answer else {
            Issue.record("no entry text: \(outcome)")
            return
        }
        #expect(!projected.complete, "8 bytes cannot hold the entry")
        #expect(projected.omittedBytes > 0)
        #expect(projected.cutAt == UInt64(projected.text.utf8.count))
        #expect(projected.text.utf8.count <= 8)
    }

    @Test func aTextBudgetOverTheContractsCeilingIsRefused() async throws {
        let opened = try #require(try await Self.opened())
        let (_, client, dict, ref) = opened
        let text = TextRenderContext(maxBodyBytes: 1 << 20, maxTextBytes: Limits.maxTextBytes + 1)
        let outcome = await client.call(.entryText(dict: dict, entry: ref, text: text))
        guard case .failure(let failure) = outcome else {
            Issue.record("an over-ceiling text budget was answered: \(outcome)")
            return
        }
        #expect(failure == .wire(.refused(.textLimitOutOfRange(requested: Limits.maxTextBytes + 1,
                                                              ceiling: Limits.maxTextBytes))))
    }
}

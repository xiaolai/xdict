import Foundation
import Testing
import XDictClient
import XDictContract

/// **`entry_gloss` through the real service** (contract 21, ADR-0037): the core resolves the recorded edition and returns
/// its first sense's own words; the app only receives the gloss. The fixture is `tiny`, whose entry `run` (occurrence 0)
/// reads `<b>run</b> to move fast …` (`conformance/fixtures/tiny/expected.json`).
struct EntryGlossServiceTests {
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

    @Test func theTinyEntrysFirstDefinitionComesBack() async throws {
        let opened = try #require(try await Self.opened())
        let (_, client, _, ref) = opened
        let outcome = await client.call(.entryGloss(entry: ref))
        guard case .success(let delivered) = outcome, case .entryGloss(let gloss) = delivered.answer else {
            Issue.record("no gloss: \(outcome)")
            return
        }
        #expect(delivered.payload == nil)
        #expect(gloss.entry == ref)
        #expect(gloss.text == "to move fast", "the entry's own words, not the headword or the sound control")
        #expect(gloss.pos == nil)
        #expect(gloss.source == .definition)
        #expect(!gloss.truncated)
    }

    /// The core resolves the edition itself: one that is not open fails, rather than answering another edition's text.
    @Test func anEditionThatIsNotOpenAnswersAFailure() async throws {
        let opened = try #require(try await Self.opened())
        let (_, client, _, _) = opened
        let missing = EntryRef(edition: Edition(rawValue: "mdx-sha256-v1:not-this-edition"), key: "run", occurrence: 0)
        let outcome = await client.call(.entryGloss(entry: missing))
        guard case .failure = outcome else {
            Issue.record("an unopened edition answered: \(outcome)")
            return
        }
    }

    @Test func aMissingEntryAnswersAFailure() async throws {
        let opened = try #require(try await Self.opened())
        let (_, client, _, ref) = opened
        let missing = EntryRef(edition: ref.edition, key: "nope", occurrence: 0)
        let outcome = await client.call(.entryGloss(entry: missing))
        guard case .failure = outcome else {
            Issue.record("a missing entry answered: \(outcome)")
            return
        }
    }
}

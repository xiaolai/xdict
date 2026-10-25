import Foundation
import Synchronization
import Testing
import XDictClient
import XDictContract

/// **The phrase question through the real service** (contract 15; `dev-docs/plan-phrase-recognition.md` WI-7): the
/// service matches the captured sentence against each open edition's own keys in the core, answers `building` until an
/// edition's inventory is built, and the build reports progress like a health check's. The fixture is `phrase`, whose
/// keys the conformance vectors describe (`conformance/phrase/CONTRACT.md`); this sentence's answer is the `contiguous`
/// vector's.
struct PhraseServiceTests {
    static let sentence = "the review was full of purple passage nobody could follow"
    static let term = PhraseTerm(location: 30, length: 7)

    static func opened(_ fixture: String) async throws -> (ServiceClient, DictId)? {
        let harness = try ServiceHarness()
        let dir = try ServiceHarness.fixtures().appending(path: fixture)
        try #require(FileManager.default.fileExists(atPath: dir.appending(path: "\(fixture).mdx").path),
                     "no \(fixture) fixture: run `make test`, or Tools/build-fixtures.sh .build/fixtures")
        let client = harness.client()
        let package = DictionaryPackage.of(mdx: dir.appending(path: "\(fixture).mdx"), volumes: [], sidecars: [])
        guard case .success = await client.importPackage(package),
              case .success(.ready(let dict, _, _)) = await client.open(package) else {
            Issue.record("the \(fixture) fixture did not import and open")
            return nil
        }
        return (client, dict)
    }

    /// **`building` first, then `found`**: the answer names the dictionary's state, the build reports its records, and
    /// the match carries the dictionary's spelling and the sentence span in UTF-16 units.
    @Test func thePhraseIsFoundOnceTheInventoryIsBuilt() async throws {
        guard let (client, dict) = try await Self.opened("phrase") else { return }
        guard case .success(let before) = await client.phrases(Self.sentence, term: Self.term, dicts: [dict]) else {
            Issue.record("the phrase question failed")
            return
        }
        #expect(before.state == .building)
        #expect(before.coverage == [PhraseCoverage(dict: dict, state: .building)])
        #expect(before.matches.isEmpty)

        let reports = Mutex<[UInt64]>([])
        let outcome = await client.submitPhrasesBuild(dict) { done, _ in reports.withLock { $0.append(done) } }.outcome()
        guard case .success(let delivered) = outcome, case .phrasesBuilt(let built) = delivered.answer else {
            Issue.record("no build answer: \(outcome)")
            return
        }
        #expect(built.phrases == 76, "the fixture's phrases, as `conformance/phrase/vectors.jsonl` counts them")
        #expect(!built.cached)
        // The build reports at its first position and its last, two deliveries NSXPC does not order against the
        // answer, and the client drops a report for a call already answered (`HealthTests`); it never reports another
        // number.
        let heard = reports.withLock { $0 }
        #expect(heard.allSatisfy { $0 == 0 || $0 == 79 }, "only the build's own positions: \(heard)")

        guard case .success(let found) = await client.phrases(Self.sentence, term: Self.term, dicts: [dict]) else {
            Issue.record("the second phrase question failed")
            return
        }
        #expect(found.state == .found)
        #expect(found.coverage == [PhraseCoverage(dict: dict, state: .ready)])
        #expect(found.matches.map(\.phrase) == ["purple passage"])
        #expect(found.total == 1 && !found.capped)
        #expect(found.matches.first?.dict == dict)
        #expect(found.matches.first?.location == 23 && found.matches.first?.length == 14)
        #expect(found.matches.first?.separation == PhraseSeparation.none && found.matches.first?.gap == 0)
    }

    /// **Each dictionary answers for itself**: with one inventory built and one not, the match is found and the
    /// coverage names both — the building one is never reported as having found nothing. With both built, a sentence
    /// nothing covers is `none`.
    @Test func theCoverageNamesEachDictionarysOwnState() async throws {
        guard let (client, phrase) = try await Self.opened("phrase") else { return }
        _ = await client.submitPhrasesBuild(phrase).outcome()
        let tinyDir = try ServiceHarness.fixtures().appending(path: "tiny")
        let tinyPackage = DictionaryPackage.of(mdx: tinyDir.appending(path: "tiny.mdx"),
                                               volumes: [tinyDir.appending(path: "tiny.mdd")],
                                               sidecars: [tinyDir.appending(path: "tiny.css")])
        guard case .success = await client.importPackage(tinyPackage),
              case .success(.ready(let tiny, _, _)) = await client.open(tinyPackage) else {
            Issue.record("the tiny fixture did not import and open")
            return
        }
        guard case .success(let partial) = await client.phrases(Self.sentence, term: Self.term, dicts: [phrase, tiny])
        else {
            Issue.record("the phrase question failed")
            return
        }
        #expect(partial.state == .found)
        #expect(partial.coverage == [PhraseCoverage(dict: phrase, state: .ready),
                                     PhraseCoverage(dict: tiny, state: .building)])

        _ = await client.submitPhrasesBuild(tiny).outcome()
        guard case .success(let none) = await client.phrases("a quiet afternoon", term: PhraseTerm(location: 2, length: 5),
                                                             dicts: [phrase, tiny]) else {
            Issue.record("the second phrase question failed")
            return
        }
        #expect(none.state == .none, "both inventories answered; nothing matched")
        #expect(none.coverage == [PhraseCoverage(dict: phrase, state: .ready),
                                  PhraseCoverage(dict: tiny, state: .ready)])
        #expect(none.matches.isEmpty)
    }
}

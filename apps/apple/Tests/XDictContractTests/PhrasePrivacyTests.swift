import Foundation
import Testing
import XDictContract

/// **The captured sentence's second local consumer** (ADR-0033 d.11; `conformance/capture/CONTRACT.md` §6): the phrase
/// question carries the sentence to the dictionary service — the one new reader, on this Mac — and nothing comes back
/// with it: the answer holds keys and spans, never the sentence. This is the capture contract's canary for that reader,
/// beside `CapturePrivacyCanaryTests`, which still scans what capture itself holds.
struct PhrasePrivacyTests {
    /// Inside the sentence, never in a term or a key: what a leak would carry and what the scans look for.
    static let marker = "CANARY-4b7e"
    static let sentence = "\(marker) they took the delay into account before deciding."

    @Test func thePhraseRequestCarriesTheSentenceAndTheAnswerDoesNot() throws {
        let request = Fixtures.request(.phrases(sentence: Self.sentence, term: PhraseTerm(location: 16, length: 27),
                                                dicts: [Fixtures.dict]),
                                       id: 77)
        let asked = try #require(String(data: try request.encoded(), encoding: .utf8))
        #expect(asked.contains(Self.marker), "the phrase question is the sentence's second consumer (D11)")

        let answer = Answer.phrases(PhraseAnswer(state: .found, matches: [], coverage: [], total: 0, capped: false))
        let reply = try #require(String(data: try Response(id: 77, outcome: .answer(answer)).encoded(), encoding: .utf8))
        #expect(!reply.contains(Self.marker), "the answer returned the sentence")
    }

    /// **No other operation carries a sentence**: the enum's only sentence field is the phrase question's, and the one
    /// other place a sentence travels — the history's reading — is the ledger's, named in the capture contract.
    @Test func noOtherOperationCarriesASentence() throws {
        for operation in Fixtures.operations {
            if case .phrases = operation { continue }
            switch operation {
            case .ledgerRecord(let reading, _, _):
                #expect(reading.sentence == Fixtures.ledgerReading.sentence, "the history's reading, as the fixture")
            default:
                let json = try #require(String(data: try Fixtures.request(operation).encoded(), encoding: .utf8))
                #expect(!json.contains(Self.marker), "\(operation) carried a sentence")
            }
        }
    }
}

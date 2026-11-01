import Foundation
import Testing
@testable import XDictContract

/// **The gloss on the wire** (contract 21, ADR-0037): one operation and one answer, no payload, the recorded edition's
/// files named through `editionsRead`, and a round trip that keeps the no-text case.
struct EntryGlossContractTests {
    static let dict = DictId(rawValue: "1a2b3c4d00000001")
    static let ref = EntryRef(edition: Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "ab", count: 32)),
                              key: "run", occurrence: 0)
    static let answer = Answer.entryGloss(EntryGloss(entry: ref, text: "to move fast", pos: "verb",
                                                     source: .definition, truncated: false))
    static let noText = Answer.entryGloss(EntryGloss(entry: ref, text: nil))

    @Test func anEntryGlossAnswersOnlyItsOwnRequest() {
        #expect(Self.answer.answers(.entryGloss(entry: Self.ref)))
        #expect(!Self.answer.answers(.entryText(dict: Self.dict, entry: Self.ref,
                                                text: TextRenderContext(maxBodyBytes: 1 << 20, maxTextBytes: 1 << 10))))
        #expect(!Self.answer.answers(.entry(dict: Self.dict, entry: Self.ref, render: .reader)))
    }

    @Test func anEntryGlossCarriesNoPayload() {
        #expect(!Self.answer.carriesPayload)
        #expect(Limits.payloadCeiling(for: .entryGloss(entry: Self.ref), answer: Self.answer) == nil)
    }

    @Test func theRequestReadsTheRecordedEditionsFiles() {
        let file = UUID()
        #expect(ServiceOperation.entryGloss(entry: Self.ref).editionsRead == [Self.ref.edition])
        #expect(ServiceOperation.entryGloss(entry: Self.ref)
            .filesRead(filesOf: [Self.dict: [file]], editions: [Self.ref.edition: Self.dict]) == [file])
        #expect(ServiceOperation.entryGloss(entry: Self.ref).filesRead(filesOf: [:], editions: [:]) == [])
    }

    @Test func anEntryGlossRoundTripsAndSaysWhenThereIsNoText() throws {
        for answer in [Self.answer, Self.noText] {
            let data = try JSONEncoder().encode(answer)
            #expect(try JSONDecoder().decode(Answer.self, from: data) == answer)
        }
    }
}

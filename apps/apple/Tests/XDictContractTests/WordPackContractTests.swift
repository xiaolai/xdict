import Foundation
import Testing
@testable import XDictContract

/// **The word pack, as the contract carries it** (contract 19, plan-word-exploration WI-5): Settings asks what is
/// installed, installs a file the reader chose, and removes it. The file travels as a path into the app group's
/// container — no handle, since the service reads it where the core lives — so the three calls hold no credit, name no
/// dictionary and carry no payload, and the answer says the pack or none.
struct WordPackContractTests {
    @Test func askingWhatIsInstalledIsAShortCallWithNoHandle() {
        let asked = ServiceOperation.wordPack
        #expect(Deadlines.deadline(for: asked, onFreshConnection: false) == .seconds(5))
        #expect(!asked.reportsProgress && asked.creditClass == nil && !asked.isBulk && asked.packageSpec == nil)
        #expect(asked.render == nil)
        let request = Fixtures.request(asked)
        #expect(request.refusal(handles: [HandleFacts(identity: Fixtures.identity, isRegularReadOnly: true)],
                                filesOf: Fixtures.filesOf) == .unexpectedHandles(count: 1), "no handle travels")
    }

    /// **A pack of 183 MB is read and validated in one call**, so its deadline is the longest of the short calls; the
    /// two calls that touch no file stay at five seconds.
    @Test func installingWaitsForTheWholeFileAndRemovingDoesNot() {
        #expect(Deadlines.deadline(for: .setWordPack(path: "/container/WordPack/xdict-words-en.jsonl"),
                                   onFreshConnection: false) == .seconds(60))
        #expect(Deadlines.deadline(for: .clearWordPack, onFreshConnection: false) == .seconds(5))
    }

    /// Answered by the pack and by nothing else, with no payload; both states round-trip exactly.
    @Test func thePackIsAnsweredByItAndRoundTrips() throws {
        for state in [WordPackState(pack: Fixtures.wordPack), WordPackState(pack: nil)] {
            let asked = ServiceOperation.wordPack
            let answer = Answer.wordPacked(state)
            #expect(answer.answers(asked) && !answer.carriesPayload)
            #expect(answer.answers(.clearWordPack), "installing, reporting and removing share one answer")
            #expect(!Answer.closed.answers(asked))
            let request = Fixtures.request(asked, id: 12)
            let envelope = try Response(id: request.id, outcome: .answer(answer)).encoded()
            #expect(Response.read(envelope, payload: nil, answering: request)
                    == .success(Delivered(answer: answer, payload: nil)))
            #expect(Response.read(envelope, payload: Data([1]), answering: request).isSuccess == false,
                    "no payload rides with it")
        }
        let json = String(data: try JSONEncoder().encode(Fixtures.wordPack), encoding: .utf8) ?? ""
        #expect(json.contains("\"version\":2") && json.contains("morphynet-deri"), "\(json)")
    }

    /// The pack names no dictionary, so it reads no dictionary's files — the service reads the container's path itself.
    @Test func thePackReadsNoDictionaryFile() {
        #expect(ServiceOperation.setWordPack(path: "/container/WordPack/a.jsonl").filesRead(filesOf: Fixtures.filesOf)
                == [])
        #expect(ServiceOperation.wordPack.filesRead(filesOf: Fixtures.filesOf) == [])
    }
}

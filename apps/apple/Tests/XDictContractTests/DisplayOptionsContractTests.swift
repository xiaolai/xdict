import Foundation
import Testing
import XDictContract

/// **A dictionary's display options, as the contract carries them** (ADR-0013 decisions 2, 4 and 6; contract 7): the
/// app asks the service which options an open dictionary declares; the service asks the core, which reads the edition's
/// markup. A short call naming one open dictionary, holding no credit and no handle; the answer is the core's catalogue
/// entry for that edition and its CSS, carried in the JSON, never as a payload.
struct DisplayOptionsContractTests {
    @Test func theContractIsVersion8() {
        #expect(Contract.version == 8)
    }

    @Test func askingForDisplayOptionsIsAShortCallOnTheNamedDictionary() {
        let asked = ServiceOperation.displayOptions(dict: Fixtures.dict)
        #expect(Deadlines.deadline(for: asked, onFreshConnection: false) == .seconds(15))
        #expect(!asked.reportsProgress && asked.creditClass == nil && !asked.isBulk && asked.packageSpec == nil)
        #expect(asked.render == nil)
        let request = Fixtures.request(asked)
        #expect(request.refusal(handles: [HandleFacts(identity: Fixtures.identity, isRegularReadOnly: true)],
                                filesOf: Fixtures.filesOf) == .unexpectedHandles(count: 1), "no handle travels")
    }

    /// Answered by display options and by nothing else, with no payload; the JSON round-trips exactly.
    @Test func displayOptionsAreAnsweredByThemAndRoundTrip() throws {
        let asked = ServiceOperation.displayOptions(dict: Fixtures.dict)
        let answer = Answer.displayOptions(Fixtures.displayOptions)
        #expect(answer.answers(asked) && !answer.carriesPayload)
        #expect(!Answer.readingStyle(Fixtures.readingStyle).answers(asked))
        #expect(!answer.answers(.readingStyle(dict: Fixtures.dict)))
        let request = Fixtures.request(asked, id: 9)
        let envelope = try Response(id: request.id, outcome: .answer(answer)).encoded()
        #expect(Response.read(envelope, payload: nil, answering: request) == .success(Delivered(answer: answer, payload: nil)))
        #expect(Response.read(envelope, payload: Data([1]), answering: request).isSuccess == false, "no payload rides with it")
        let json = try #require(String(data: envelope, encoding: .utf8))
        #expect(json.contains("defaultValue") && json.contains("data-xdict-opt-pronunciation"), "\(json)")
    }

    /// An edition that declares nothing is answered with no options and no CSS, not a failure.
    @Test func noOptionsIsAnAnswer() throws {
        let none = Answer.displayOptions(DisplayOptions(version: 1, options: [], css: ""))
        let request = Fixtures.request(.displayOptions(dict: Fixtures.dict), id: 3)
        let envelope = try Response(id: request.id, outcome: .answer(none)).encoded()
        #expect(Response.read(envelope, payload: nil, answering: request) == .success(Delivered(answer: none, payload: nil)))
    }
}

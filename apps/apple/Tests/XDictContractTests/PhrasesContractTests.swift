import Foundation
import Testing
import XDictContract

/// **The phrase question, as the contract carries it** (contract 15; `dev-docs/plan-phrase-recognition.md` WI-7): the
/// app asks the service which phrase covers a captured term; the service asks the core, which matches against each
/// open edition's own keys. A credited lookup-class call naming its dictionaries, the sentence in the JSON; the answer
/// carries every match with its UTF-16 span and the state of each dictionary that could not answer. The inventory's
/// build is a background call, like the examples store's.
struct PhrasesContractTests {
    static let sentence = "the review was full of purple passage nobody could follow"
    static let term = PhraseTerm(location: 30, length: 7)

    static func asked() -> ServiceOperation {
        .phrases(sentence: sentence, term: term, dicts: [Fixtures.dict, Fixtures.other])
    }

    @Test func askingForPhrasesIsALookupClassCallNamingItsDictionaries() {
        let asked = Self.asked()
        #expect(Deadlines.deadline(for: asked, onFreshConnection: false) == .seconds(5))
        #expect(asked.creditClass == .lookup && !asked.isBulk && !asked.reportsProgress && asked.packageSpec == nil)
        #expect(asked.render == nil)
        #expect(asked.filesRead(filesOf: Fixtures.filesOf) == Fixtures.package.files.map(\.id) + [Fixtures.otherMDXID])
        let request = Fixtures.request(asked)
        #expect(request.refusal(handles: [], filesOf: Fixtures.filesOf) == nil)
    }

    @Test func buildingTheInventoryIsABackgroundCallOnOneDictionary() {
        let asked = ServiceOperation.phrasesBuild(dict: Fixtures.dict)
        #expect(asked.reportsProgress && asked.creditClass == nil && !asked.isBulk && asked.packageSpec == nil)
        #expect(Deadlines.deadline(for: asked, onFreshConnection: false) == nil, "bounded by silence, not a deadline")
        #expect(asked.filesRead(filesOf: Fixtures.filesOf) == Fixtures.package.files.map(\.id))
        #expect(Fixtures.request(asked).refusal(handles: [], filesOf: Fixtures.filesOf) == nil)
    }

    /// Answered by their own operations and by nothing else, with no payload; the JSON round-trips exactly.
    @Test func phrasesAreAnsweredByPhrasesAndTheBuildByTheBuild() throws {
        let asked = Self.asked()
        let answer = Answer.phrases(Fixtures.phrases)
        #expect(answer.answers(asked) && !answer.carriesPayload)
        #expect(!Answer.phrasesBuilt(Fixtures.phrasesBuilt).answers(asked))
        #expect(!answer.answers(.phrasesBuild(dict: Fixtures.dict)))
        let request = Fixtures.request(asked, id: 9)
        let envelope = try Response(id: request.id, outcome: .answer(answer)).encoded()
        #expect(Response.read(envelope, payload: nil, answering: request)
                == .success(Delivered(answer: answer, payload: nil)))
        #expect(Response.read(envelope, payload: Data([1]), answering: request).isSuccess == false,
                "no payload rides with it")
        let json = try #require(String(data: envelope, encoding: .utf8))
        #expect(json.contains("purple passage") && json.contains("marked") && json.contains("unavailable"), "\(json)")

        let built = Answer.phrasesBuilt(Fixtures.phrasesBuilt)
        let buildRequest = Fixtures.request(.phrasesBuild(dict: Fixtures.dict), id: 10)
        let buildEnvelope = try Response(id: buildRequest.id, outcome: .answer(built)).encoded()
        #expect(Response.read(buildEnvelope, payload: nil, answering: buildRequest)
                == .success(Delivered(answer: built, payload: nil)))
        #expect(!built.answers(asked) && !answer.answers(.phrasesBuild(dict: Fixtures.dict)))
    }

    /// **A phrase request or reply from another version is a mismatch, never decoded**: an older pair's operation never
    /// reaches the code that would read it, in either direction.
    @Test func thePhraseQuestionIsBehindTheContractVersionBothWays() throws {
        let asked = Fixtures.request(Self.asked(), id: 31)
        let service = Contract.version + 1
        #expect(Request.receive(try asked.encoded(), handles: [], filesOf: Fixtures.filesOf, serviceContract: service)
                == .answered(Response(id: 31, outcome: .failure(
                    .contractMismatch(service: service, client: Contract.version)))))
        let older = Request(contract: Contract.version - 1, id: 32, tokens: Fixtures.tokens, operation: Self.asked())
        #expect(Request.receive(try older.encoded(), handles: [], filesOf: Fixtures.filesOf)
                == .answered(Response(id: 32, outcome: .failure(
                    .contractMismatch(service: Contract.version, client: Contract.version - 1)))))

        let request = Fixtures.request(Self.asked(), id: 33)
        let answer = Answer.phrases(Fixtures.phrases)
        let newer = try Response(contract: service, id: 33, outcome: .answer(answer)).encoded()
        #expect(Response.read(newer, payload: nil, answering: request)
                == .failure(.contractMismatch(service: service, client: Contract.version)))
        let olderReply = try Response(contract: Contract.version - 1, id: 33, outcome: .answer(answer)).encoded()
        #expect(Response.read(olderReply, payload: nil, answering: request)
                == .failure(.contractMismatch(service: Contract.version - 1, client: Contract.version)))
    }
}

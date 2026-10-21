import Foundation
import Testing
import XDictContract

/// The envelopes as both sides read them: every operation and every answer survives the wire whole, a message of
/// another contract version is answered as a mismatch and never decoded further, and the bulk payload travels beside
/// the JSON, never inside it.
struct EnvelopeTests {
    // MARK: - Every case, round-tripped

    @Test func theFixturesHoldEveryCase() {
        expectEveryCase(Fixtures.operations, Fixtures.operationCases, Fixtures.index)
        expectEveryCase(Fixtures.answers, Fixtures.answerCases, Fixtures.index)
        expectEveryCase(Fixtures.features, Fixtures.featureCases, Fixtures.index)
        expectEveryCase(Fixtures.coreFailures, Fixtures.coreFailureCases, Fixtures.index)
        expectEveryCase(Fixtures.refusals, Fixtures.refusalCases, Fixtures.index)
        expectEveryCase(Fixtures.wireErrors, Fixtures.wireErrorCases, Fixtures.index)
        expectEveryCase(Fixtures.appleRefusals, Fixtures.appleRefusalCases, Fixtures.index)
        expectEveryCase(Fixtures.appleBounds, Fixtures.appleBoundCases, Fixtures.index)
    }

    /// Each operation as the service receives it: encoded by the client, admitted with the handles it needs, equal.
    @Test(arguments: Fixtures.operations)
    func everyOperationCrossesWhole(_ operation: ServiceOperation) throws {
        let sent = Fixtures.request(operation, id: 9_000_000_000)
        let received = Request.receive(try sent.encoded(), handles: Fixtures.handles(for: operation), filesOf: Fixtures.filesOf)
        #expect(received == .admitted(sent))
    }

    /// Each answer as the client receives it, with the payload its kind carries.
    @Test(arguments: Fixtures.answers)
    func everyAnswerCrossesWhole(_ answer: Answer) throws {
        let request = Fixtures.request(Self.operation(answering: answer))
        let payload = answer.carriesPayload ? Data("<p>body</p>".utf8) : nil
        let envelope = try Response(id: request.id, outcome: .answer(answer)).encoded()
        let read = Response.read(envelope, payload: payload, answering: request)
        #expect(read == .success(Delivered(answer: answer, payload: payload)))
    }

    /// Every error kind, including those only the client makes (`interrupted`, `invalidated`, `timedOut`), round-trips:
    /// a service may hand any of them back as a value, and a log may hold any of them.
    @Test(arguments: Fixtures.wireErrors)
    func everyErrorCrossesWhole(_ error: WireError) throws {
        let request = Fixtures.request(.versions)
        let envelope = try Response(id: request.id, outcome: .failure(error)).encoded()
        #expect(Response.read(envelope, payload: nil, answering: request) == .failure(error))
    }

    @Test func anEventCrossesWhole() throws {
        let event = ServiceEvent(request: 41, kind: .progress(done: 4 << 20, total: 745_000_000))
        #expect(ServiceEvent.read(try event.encoded()) == .success(event))
    }

    // MARK: - Versions

    /// **A request of another contract version is answered as a mismatch, never decoded further**: its operation may
    /// be one this service has never heard of, so only `contract` and `id` are read.
    @Test func aRequestOfAnotherVersionIsAMismatchAnswer() {
        let next = Contract.version + 1
        let future = Data(#"{"contract":\#(next),"id":31,"tokens":[],"operation":{"frobnicate":{"how":"hard"}}}"#.utf8)
        #expect(Request.receive(future, handles: [], filesOf: [:]) == .answered(
            Response(id: 31, outcome: .failure(.contractMismatch(service: Contract.version, client: next)))))
    }

    /// The same request at this version is not refused for its version: the check reads the number, not the shape.
    @Test func theSameShapeAtThisVersionIsUndecodableNotAMismatch() {
        let unknown = Data(#"{"contract":\#(Contract.version),"id":31,"tokens":[],"operation":{"frobnicate":{}}}"#.utf8)
        guard case .answered(let response) = Request.receive(unknown, handles: [], filesOf: [:]),
              case .failure(.undecodable) = response.outcome, response.id == 31
        else { Issue.record("an unknown operation at this version was not undecodable"); return }
    }

    /// And the other way: a reply from a service of another version is a mismatch to the client, whatever it says.
    @Test func aReplyOfAnotherVersionIsAMismatch() {
        let request = Fixtures.request(.versions, id: 5)
        let next = Contract.version + 1
        let future = Data(#"{"contract":\#(next),"id":5,"outcome":{"brandNew":{}}}"#.utf8)
        #expect(Response.read(future, payload: nil, answering: request)
                == .failure(.contractMismatch(service: next, client: Contract.version)))
    }

    @Test func anEventOfAnotherVersionIsAMismatch() {
        let next = Contract.version + 1
        let future = Data(#"{"contract":\#(next),"request":1,"kind":{"sparkle":{}}}"#.utf8)
        #expect(ServiceEvent.read(future) == .failure(.contractMismatch(service: next, client: Contract.version)))
    }

    @Test func bytesThatAreNoEnvelopeAreUndecodableWithNoID() {
        for garbage in [Data(), Data("not json".utf8), Data(#"{"id":4}"#.utf8), Data(#"{"contract":"1","id":4}"#.utf8)] {
            guard case .answered(let response) = Request.receive(garbage, handles: [], filesOf: [:]),
                  case .failure(.undecodable) = response.outcome
            else { Issue.record("\(String(decoding: garbage, as: UTF8.self)) was not undecodable"); continue }
            // An id is echoed only when it could be read; these four carry none the service can trust.
            #expect(response.id == nil || response.id == 4)
        }
    }

    // MARK: - The payload

    /// **The entry's HTML is the payload, never the JSON**: the envelope holds the entry's reference, its policy and its
    /// lossy count, and not one byte of the body.
    @Test func anEntryAnswersJSONHoldsNoHTML() throws {
        let html = "<div class=\"entry\"><b>hold</b> verb — to have in your hand</div>"
        let answer = Answer.entry(Entry(entry: Fixtures.entryRef, csp: "default-src 'none'", lossyBytes: 0))
        let envelope = try Response(id: 7, outcome: .answer(answer)).encoded()
        let json = String(decoding: envelope, as: UTF8.self)
        #expect(!json.contains("<div"), "\(json)")
        #expect(!json.contains("to have in your hand"))
        let entry = try #require(try Self.object(envelope, at: ["outcome", "answer", "_0", "entry", "_0"]))
        #expect(Set(entry.keys) == ["entry", "csp", "lossyBytes"])

        let read = Response.read(envelope, payload: Data(html.utf8), answering: Fixtures.request(
            .entry(dict: Fixtures.dict, entry: Fixtures.entryRef, render: .reader)))
        #expect(read == .success(Delivered(answer: answer, payload: Data(html.utf8))))
    }

    /// A found resource's bytes are the payload too; its JSON holds its path and type only.
    @Test func aResourceAnswersJSONHoldsNoBytes() throws {
        let answer = Answer.resource(.found(path: "a.png", mime: "image/png"))
        let envelope = try Response(id: 7, outcome: .answer(answer)).encoded()
        let found = try #require(try Self.object(envelope, at: ["outcome", "answer", "_0", "resource", "_0", "found"]))
        #expect(Set(found.keys) == ["path", "mime"])
    }

    /// The payload is there exactly when the answer's kind carries one: an entry or a found resource without it, or
    /// anything else with one, is a defect of the service, reported as such and never passed on.
    @Test func aPayloadWhereNoneBelongsOrNoneWhereOneDoesIsUndecodable() throws {
        let entryRequest = Fixtures.request(.entry(dict: Fixtures.dict, entry: Fixtures.entryRef, render: .reader))
        let entry = try Response(id: 7, outcome: .answer(.entry(Entry(entry: Fixtures.entryRef, csp: "", lossyBytes: 0))))
            .encoded()
        guard case .failure(.undecodable) = Response.read(entry, payload: nil, answering: entryRequest)
        else { Issue.record("an entry without its HTML was passed on"); return }

        let versionsRequest = Fixtures.request(.versions)
        let versions = try Response(id: 7, outcome: .answer(.versions(Versions(
            protocolVersion: 1, core: "0", indexFormat: 1, normalization: 1)))).encoded()
        guard case .failure(.undecodable) = Response.read(versions, payload: Data([1]), answering: versionsRequest)
        else { Issue.record("a payload beside versions was passed on"); return }
    }

    /// Over the ceiling the client holds for its kind, a payload is refused before anything sees it: here an entry,
    /// held to the view's body limit.
    @Test func aPayloadOverItsCeilingIsRefused() throws {
        let small = RenderContext(maxBodyBytes: 8)
        let request = Fixtures.request(.entry(dict: Fixtures.dict, entry: Fixtures.entryRef, render: small))
        let envelope = try Response(id: 7, outcome: .answer(.entry(Entry(entry: Fixtures.entryRef, csp: "", lossyBytes: 0))))
            .encoded()
        #expect(Response.read(envelope, payload: Data(count: 9), answering: request)
                == .failure(.refused(.payloadTooLarge(bytes: 9, limit: 8))))
        #expect(Response.read(envelope, payload: Data(count: 8), answering: request).isSuccess)
    }

    /// **A resource WebKit renders as a document or a body is held to the view's ceiling, like an entry** (Codex
    /// objection 9): HTML, SVG, XHTML, XML, CSS and JavaScript. Anything else (an image, a recording, a font) only to
    /// the core's 64 MiB. Codex's check: nine bytes of `text/html` against a ceiling of eight.
    @Test func aRenderedResourceIsHeldToTheViewsCeiling() throws {
        let request = Fixtures.request(.resource(dict: Fixtures.dict, path: "a.html", render: RenderContext(maxBodyBytes: 8)))
        let held = ["text/html", "image/svg+xml", "application/xhtml+xml", "text/xml", "application/xml", "text/css",
                    "text/javascript", "TEXT/HTML; charset=utf-8"]
        for mime in held {
            let envelope = try Response(id: 7, outcome: .answer(.resource(.found(path: "a", mime: mime)))).encoded()
            #expect(Response.read(envelope, payload: Data(count: 9), answering: request)
                    == .failure(.refused(.payloadTooLarge(bytes: 9, limit: 8))), "\(mime)")
            #expect(Response.read(envelope, payload: Data(count: 8), answering: request).isSuccess, "\(mime)")
        }
        for mime in ["image/png", "audio/mpeg", "font/woff2", "application/octet-stream"] {
            let envelope = try Response(id: 7, outcome: .answer(.resource(.found(path: "a", mime: mime)))).encoded()
            #expect(Response.read(envelope, payload: Data(count: 9), answering: request).isSuccess, "\(mime)")
        }
        let image = Answer.resource(.found(path: "a.png", mime: "image/png"))
        #expect(Limits.payloadCeiling(for: request.operation, answer: image) == Limits.maxResourceBytes)
    }

    /// A reply or an event larger than `Limits.maxEnvelopeBytes` is refused before it is decoded.
    @Test func anOversizedReplyOrEventIsRefusedBeforeDecoding() {
        let huge = Data(repeating: UInt8(ascii: " "), count: Int(Limits.maxEnvelopeBytes) + 1)
        let refusal = WireError.refused(.envelopeTooLarge(bytes: Limits.maxEnvelopeBytes + 1, limit: Limits.maxEnvelopeBytes))
        #expect(Response.read(huge, payload: nil, answering: Fixtures.request(.versions)) == .failure(refusal))
        #expect(ServiceEvent.read(huge) == .failure(refusal))
    }

    /// Join and split answer the lineage the edition now has; only `lineageOf` may answer none (an edition the
    /// registry does not know).
    @Test func onlyLineageOfMayAnswerNoLineage() throws {
        let none = try Response(id: 7, outcome: .answer(.lineage(nil))).encoded()
        for operation: ServiceOperation in [.joinLineage(edition: Fixtures.edition, lineage: Fixtures.lineage),
                                            .splitLineage(edition: Fixtures.edition, newLineage: Fixtures.newLineage)] {
            guard case .failure(.undecodable) = Response.read(none, payload: nil, answering: Fixtures.request(operation))
            else { Issue.record("\(operation) answered with no lineage was passed on"); continue }
        }
        #expect(Response.read(none, payload: nil, answering: Fixtures.request(.lineageOf(edition: Fixtures.edition)))
                == .success(Delivered(answer: .lineage(nil), payload: nil)))
    }

    /// A reply must answer what was asked: another request's id, or another operation's kind of answer, is a defect.
    @Test func aReplyToSomethingElseIsUndecodable() throws {
        let request = Fixtures.request(.close(dict: Fixtures.dict), id: 8)
        let otherID = try Response(id: 9, outcome: .answer(.closed)).encoded()
        guard case .failure(.undecodable) = Response.read(otherID, payload: nil, answering: request)
        else { Issue.record("a reply to request 9 was taken as request 8's"); return }
        let otherKind = try Response(id: 8, outcome: .answer(.suggestions([]))).encoded()
        guard case .failure(.undecodable) = Response.read(otherKind, payload: nil, answering: request)
        else { Issue.record("suggestions were taken as the answer to close"); return }
        // A failure the service could not tie to an id (it could not read the request) is still that failure.
        let unread = try Response(id: nil, outcome: .failure(.undecodable(detail: "no header"))).encoded()
        #expect(Response.read(unread, payload: nil, answering: request) == .failure(.undecodable(detail: "no header")))
    }

    // MARK: - Helpers

    static func operation(answering answer: Answer) -> ServiceOperation {
        let operation = Fixtures.operations.first { answer.answers($0) }
        return operation ?? .versions
    }

    static func object(_ json: Data, at path: [String]) throws -> [String: Any]? {
        var node: Any? = try JSONSerialization.jsonObject(with: json)
        for key in path { node = (node as? [String: Any])?[key] }
        return node as? [String: Any]
    }
}

/// Every index in `0..<count` appears among `values`, and nothing else: a case with no fixture, or a fixture list
/// counted against a stale total, is named.
func expectEveryCase<T>(_ values: [T], _ count: Int, _ index: (T) -> Int,
                        sourceLocation: SourceLocation = #_sourceLocation) {
    let seen = Set(values.map(index))
    let missing = Set(0..<count).subtracting(seen).sorted(), outside = seen.subtracting(0..<count).sorted()
    #expect(seen == Set(0..<count), "cases without a fixture: \(missing); out of range: \(outside)",
            sourceLocation: sourceLocation)
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

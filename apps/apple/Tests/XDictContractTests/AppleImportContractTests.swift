import Foundation
import Testing
import XDictContract

/// **Converting an Apple dictionary, as the contract says it** (ADR-0011 decisions 4, 5 and 11; contract 6): the
/// request names a staging folder by UUID and no path, sends no handle, reads no dictionary's files, holds no credit and
/// is bounded by the silence between its progress events; the reply carries what was converted; a refusal is a kind,
/// never a sentence.
struct AppleImportContractTests {
    @Test func theContractIsVersion6() {
        #expect(Contract.version == 6)
    }

    @Test func aConversionIsALongCallNamingOnlyItsStagingFolder() throws {
        let convert = ServiceOperation.convertApple(staging: Fixtures.staging)
        #expect(convert.reportsProgress && Deadlines.deadline(for: convert, onFreshConnection: true) == nil)
        #expect(convert.creditClass == nil && !convert.isBulk && convert.packageSpec == nil && convert.render == nil)
        let json = try #require(String(data: try Fixtures.request(convert).encoded(), encoding: .utf8))
        #expect(json.contains(Fixtures.staging.uuidString) && !json.contains("/"), "no path travels: \(json)")
    }

    /// No handle travels with a conversion (ADR-0009 decision 1): the service resolves the UUID in its own container.
    @Test func aConversionSentWithHandlesIsRefused() {
        let request = Fixtures.request(.convertApple(staging: Fixtures.staging))
        let handle = HandleFacts(identity: Fixtures.identity, isRegularReadOnly: true)
        #expect(request.refusal(handles: [handle], filesOf: Fixtures.filesOf) == .unexpectedHandles(count: 1))
        #expect(request.refusal(handles: [], filesOf: Fixtures.filesOf) == nil)
    }

    @Test func cancellingAConversionIsAShortCallAnsweredByACancellation() {
        let cancel = ServiceOperation.cancelConversion
        #expect(!cancel.reportsProgress && cancel.creditClass == nil)
        #expect(Deadlines.deadline(for: cancel, onFreshConnection: false) == .seconds(2))
        #expect(Answer.cancellation(.stopping).answers(cancel) && Answer.cancellation(.notRunning).answers(cancel))
        #expect(!Answer.converted(Fixtures.converted).answers(cancel))
    }

    /// A conversion is answered by what it converted and by nothing else; the converted answer carries no payload.
    @Test func aConversionIsAnsweredByWhatItConverted() throws {
        let request = Fixtures.request(.convertApple(staging: Fixtures.staging), id: 12)
        let reply = try Response(id: 12, outcome: .answer(.converted(Fixtures.converted))).encoded()
        #expect(Response.read(reply, payload: nil, answering: request) == .success(Delivered(answer: .converted(Fixtures.converted),
                                                                                             payload: nil)))
        let wrong = try Response(id: 12, outcome: .answer(.closed)).encoded()
        guard case .failure(.undecodable) = Response.read(wrong, payload: nil, answering: request) else {
            Issue.record("a closed answer was accepted for a conversion")
            return
        }
        let lookup = Fixtures.request(.lookup(query: "a", dicts: [], options: LookupOptions(limit: 1, offset: 0, mode: .reader,
                                                                                          generation: nil)), id: 12)
        guard case .failure(.undecodable) = Response.read(reply, payload: nil, answering: lookup) else {
            Issue.record("a converted answer was accepted for a lookup")
            return
        }
    }

    /// Each refusal survives the wire as the same kind with the same data: the shell words it (ADR-0007 decision 10).
    @Test(arguments: Fixtures.appleRefusals)
    func aRefusalSurvivesTheWire(_ refusal: AppleImportRefusal) throws {
        let request = Fixtures.request(.convertApple(staging: Fixtures.staging), id: 3)
        let reply = try Response(id: 3, outcome: .failure(.appleImport(refusal))).encoded()
        #expect(Response.read(reply, payload: nil, answering: request) == .failure(.appleImport(refusal)))
    }
}

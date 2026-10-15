import Foundation
import Testing
import XDictClient
import XDictContract
import XDictLibrary
@testable import XDictSearch

/// The library's phases as the search reads them, the failures it words, and the trail on its own.
struct SourceAndTrailTests {
    @Test func everyPhaseReadsAsItsState() {
        let handle = DictId(rawValue: "h")
        #expect(SourceState(.ready, handle: handle) == .ready(handle))
        #expect(SourceState(.ready, handle: nil) == .indexing(fraction: nil), "ready with no handle is not answering yet")
        #expect(SourceState(nil, handle: nil) == .indexing(fraction: nil))
        #expect(SourceState(.waiting, handle: nil) == .indexing(fraction: nil))
        #expect(SourceState(.opening, handle: nil) == .indexing(fraction: nil))
        #expect(SourceState(.cancelling, handle: nil) == .indexing(fraction: nil))
        #expect(SourceState(.importing(done: 1, total: 4), handle: nil) == .indexing(fraction: 0.25))
        #expect(SourceState(.importing(done: 0, total: 0), handle: nil) == .indexing(fraction: nil))
        #expect(SourceState(.cancelled, handle: nil) == .notImported(.cancelled))
        #expect(SourceState(.refused(.registrationCode), handle: nil) == .refused(.registrationCode))
        #expect(SourceState(.failed(.serviceFailed), handle: nil) == .notImported(.serviceFailed))
        #expect(SourceState(.missing(fileName: "a.mdx"), handle: nil) == .missing(fileName: "a.mdx"))
        #expect(SourceState(.outsideItsFolder(fileName: "b.mdd"), handle: nil) == .outsideItsFolder(fileName: "b.mdd"))
    }

    /// Q11's five, from the states: damaged is malformed, every other permanent refusal unsupported.
    @Test func unavailableStatesAreToldApart() {
        #expect(Unavailable(.refused(.damaged)) == .malformed)
        for refusal: ImportRefusal in [.formatVersion("4.0"), .resourceLibraryV3, .registrationCode, .encrypted, .compression,
                                       .encoding("EUC-JP"), .tooLarge] {
            #expect(Unavailable(.refused(refusal)) == .unsupported(refusal))
        }
        #expect(Unavailable(.missing(fileName: "x")) == .missingFile("x"))
        #expect(Unavailable(.notImported(.missingFile("y"))) == .missingFile("y"))
        #expect(Unavailable(.indexing(fraction: 0.5)) == .indexing(fraction: 0.5))
    }

    @Test func lookupFailuresAreKindsAndASupersededCallIsNone() {
        #expect(LookupFailure(.superseded) == nil)
        #expect(LookupFailure(.wire(.core(.malformed(detail: "")))) == .malformed)
        #expect(LookupFailure(.wire(.core(.sourceChanged(detail: "")))) == .changed)
        #expect(LookupFailure(.reopenNeedsImport(dict: DictId(rawValue: "h"), reason: .changed)) == .changed)
        #expect(LookupFailure(.wire(.core(.tooLarge(limit: .page, detail: "")))) == .tooLarge)
        #expect(LookupFailure(.wire(.interrupted)) == .serviceFailed)
        #expect(LookupFailure(.wire(.timedOut(deadline: .seconds(1)))) == .serviceFailed)
        #expect(LookupFailure(.wire(.core(.staleHandle(detail: "")))) == .serviceFailed)
    }

    static func visit(_ query: String, origin: Bool = true) -> Visit {
        Visit(query: query, mode: origin ? .reader : .link, scope: .all, isOrigin: origin)
    }

    @Test func theTrailGoesBackForwardAndToItsOrigin() {
        var trail = Trail()
        #expect(trail.current == nil && !trail.canGoBack && !trail.canGoForward && !trail.canReturnToOrigin)
        trail.push(Self.visit("typed"))
        for hop in 1...3 { trail.push(Self.visit("link\(hop)", origin: false)) }
        #expect(trail.current?.query == "link3")
        #expect(trail.back()?.query == "link2")
        #expect(trail.forward()?.query == "link3")
        #expect(trail.forward() == nil)
        #expect(trail.toOrigin()?.query == "typed")
        #expect(!trail.canReturnToOrigin, "at the origin, there is nowhere to return to")
        #expect(trail.canGoForward)
        trail.push(Self.visit("again"))
        #expect(trail.visits.map(\.query) == ["typed", "again"], "a new place drops what lay ahead")
    }

    /// The origin is the last typed word at or before the current place, not after it, and not the first.
    @Test func theOriginIsTheLastTypedWordBeforeHere() {
        var trail = Trail()
        trail.push(Self.visit("first"))
        trail.push(Self.visit("hop", origin: false))
        trail.push(Self.visit("second"))
        trail.push(Self.visit("hop again", origin: false))
        #expect(trail.toOrigin()?.query == "second")
        _ = trail.back()
        _ = trail.back()
        #expect(trail.current?.query == "first")
        #expect(!trail.canReturnToOrigin)
    }

    @Test func theTrailKeepsItsMostRecentPlaces() {
        var trail = Trail()
        for n in 0..<(Trail.capacity + 7) { trail.push(Self.visit("w\(n)")) }
        #expect(trail.visits.count == Trail.capacity)
        #expect(trail.visits.first?.query == "w7")
        #expect(trail.current?.query == "w\(Trail.capacity + 6)")
    }
}

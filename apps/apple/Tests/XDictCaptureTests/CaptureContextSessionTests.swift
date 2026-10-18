import Foundation
import Testing
@testable import XDictCapture

/// **The one ephemeral session the sentence lives in** (ADR-0014 decision 9): the context of the request being presented,
/// in memory only, replaced by the next, dropped when presentation ends — and described by metadata alone, so no log,
/// dump or observation hook that touches it can write the reader's text.
struct CaptureContextSessionTests {
    private static let sentence = "The tide was high that night."

    private func available() -> ContextOutcome {
        .available(sentence: Self.sentence, term: NSRange(location: 4, length: 4), cut: [], gap: nil)
    }

    @Test func itHoldsOneContextAndTheNextReplacesIt() {
        let session = CaptureContextSession()
        session.hold(available(), request: 3, generation: 7)
        #expect(session.context(request: 3, generation: 7) == available())
        #expect(session.context(request: 3, generation: 6) == nil, "another generation's context was handed out")
        session.hold(.unavailable(.notCaptured), request: 4, generation: 8)
        #expect(session.context(request: 3, generation: 7) == nil, "two contexts were kept")
        #expect(session.context(request: 4, generation: 8) == .unavailable(.notCaptured))
    }

    @Test func endingThePresentationDropsIt() {
        let session = CaptureContextSession()
        session.hold(available(), request: 3, generation: 7)
        session.end(request: 2)
        #expect(session.context(request: 3, generation: 7) != nil, "another request's end dropped this one")
        session.end(request: 3)
        #expect(session.context(request: 3, generation: 7) == nil)
        session.hold(available(), request: 5, generation: 9)
        session.clear()
        #expect(session.isEmpty)
    }

    /// **Metadata only**: neither its description, its debug description nor a dump names a word of the sentence.
    @Test func noDescriptionOfTheSessionCarriesTheSentence() {
        let session = CaptureContextSession()
        session.hold(available(), request: 3, generation: 7)
        var dumped = ""
        dump(session, to: &dumped)
        for text in [String(describing: session), String(reflecting: session), dumped] {
            #expect(!text.contains("tide") && !text.contains("night"), "the session described its sentence: \(text)")
        }
    }
}

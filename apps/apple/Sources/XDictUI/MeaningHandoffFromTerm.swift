import Foundation
import XDictCapture

/// **The one place a captured term becomes the AI pane's question** (ADR-0021 d.11; `conformance/capture/CONTRACT.md`
/// §6): the sentence the capture validated and the term's range in it, handed over as a value. Nothing here decides
/// whether the reader asks — that is the pane's tap, and only then — and nothing here keeps the sentence beyond the
/// presentation. `CaptureContextFlowTests.theAIConsumerIsOneFileAndOneRead` holds this to exactly one context read, so
/// admitting this file admits no second reader of a captured sentence.
extension MeaningHandoff {
    /// Nil when the capture carries no sentence: an "in context" ask without one is not offered.
    public init?(term: CapturedTerm, origin: MeaningOrigin) {
        guard case .available(let sentence, let range, _, _) = term.context else { return nil }
        self.init(term: term.term, sentence: sentence, range: range, origin: origin)
    }
}

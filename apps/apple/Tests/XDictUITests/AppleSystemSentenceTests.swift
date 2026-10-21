import Foundation
import Testing
import XDictAI
import XDictUI

/// **A capability the system does not provide is named, never hidden** (ADR-0026; owner's rule of 2026-10-21): the
/// system case words both versions, so a reader on an older Mac knows what would make Apple Intelligence work.
struct AppleSystemSentenceTests {
    @Test func theSystemSentenceNamesBothVersions() {
        let text = String(localized: MeaningSentences.availability(.system(required: "27", running: "15.7")))
        #expect(text.contains("27"), "the version the source needs: \(text)")
        #expect(text.contains("15.7"), "the version this Mac runs: \(text)")
    }

    /// Every availability reason has a sentence of its own: a new case cannot silently read as `.unknown`.
    @Test func everyReasonHasADistinctSentence() {
        let sentences = AppleAvailability.allCases.map {
            String(localized: MeaningSentences.availability($0))
        }
        #expect(Set(sentences).count == AppleAvailability.allCases.count)
    }
}

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

    /// Every availability reason has a sentence of its own: a new case cannot silently read as `.unknown`. The list is
    /// sayso's payload-free cases plus the system case with sample versions — the type itself is no longer `CaseIterable`,
    /// because a system case is infinitely variable and never belongs in one (sayso 0.5.0).
    static let reasons: [AppleAvailability] = AppleAvailability.fixedCases
        + [.system(required: "27", running: "15.7")]

    @Test func everyReasonHasADistinctSentence() {
        let sentences = Self.reasons.map {
            String(localized: MeaningSentences.availability($0))
        }
        #expect(Set(sentences).count == Self.reasons.count)
    }
}

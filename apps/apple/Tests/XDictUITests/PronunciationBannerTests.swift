import Testing
import XDictSearch
@testable import XDictUI

/// **How long a sound's notice stays** (plan-macos-v1 WI-7, WI-11): a notice goes after a few seconds; the one-time tip
/// that a better voice can be downloaded is shown once, so it stays until the reader closes it.
@MainActor
struct PronunciationBannerTests {
    /// **Only what differs from what was asked is said** (UI review M-15): a word spoken as asked, or a recording that
    /// plays, needs no notice; a fallback, a problem or a voice tip does.
    @Test func aWordSpokenAsAskedNeedsNoNotice() {
        #expect(!PronunciationBanner.shows(.speech(.spoken(voice: "Samantha", language: "en-US")), hasTip: false))
        #expect(!PronunciationBanner.shows(.recording(format: "mp3"), hasTip: false))
        #expect(PronunciationBanner.shows(.speech(.spoken(voice: "Samantha", language: "en-US")), hasTip: true))
        #expect(PronunciationBanner.shows(.fallback(.missing(path: "a.spx"), .spoken(voice: "Samantha", language: "en-US")), hasTip: false))
    }

    @Test func aNoticeGoesByItselfAndTheVoiceTipStaysUntilClosed() {
        #expect(PronunciationBanner.dismissal(hasTip: false) == .seconds(6))
        #expect(PronunciationBanner.dismissal(hasTip: true) == nil)
    }
}

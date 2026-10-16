import Testing
@testable import XDictUI

/// **How long a sound's notice stays** (plan-macos-v1 WI-7, WI-11): a notice goes after a few seconds; the one-time tip
/// that a better voice can be downloaded is shown once, so it stays until the reader closes it.
@MainActor
struct PronunciationBannerTests {
    @Test func aNoticeGoesByItselfAndTheVoiceTipStaysUntilClosed() {
        #expect(PronunciationBanner.dismissal(hasTip: false) == .seconds(6))
        #expect(PronunciationBanner.dismissal(hasTip: true) == nil)
    }
}

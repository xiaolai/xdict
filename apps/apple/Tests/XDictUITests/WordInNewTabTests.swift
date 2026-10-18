import Testing
@testable import XDictUI

/// **A ⌘-clicked word reaches only the tab it opened** (parity P47): handed over before that tab's window is made, taken
/// once by it within `NewTabLookups.bound`, and dropped when the tab is not made, when File ▸ New Tab opens another
/// window, or when the bound passes. No later, unrelated window inherits it.
@MainActor
struct WordInNewTabTests {
    let start = ContinuousClock.now

    @Test func aHandedWordIsTakenOnceByTheTabItOpened() {
        let tabs = NewTabLookups()
        #expect(tabs.take(now: start) == nil, "a window made at launch looks nothing up")
        tabs.hand("apple", now: start)
        tabs.hand("pear", now: start)
        #expect(tabs.take(now: start + .milliseconds(100)) == "pear", "the latest click's word")
        #expect(tabs.take(now: start + .milliseconds(100)) == nil, "taken once")
    }

    @Test func aWindowOpenedByNewTabDoesNotTakeAPendingWord() {
        let tabs = NewTabLookups()
        tabs.hand("apple", now: start)
        tabs.cancel()   // File ▸ New Tab, before it opens its window
        #expect(tabs.take(now: start) == nil)
    }

    @Test func aFailedCreationClearsTheWord() {
        let tabs = NewTabLookups()
        tabs.hand("apple", now: start)
        tabs.failed("apple")
        #expect(tabs.take(now: start) == nil)
        // A failure reported late, after a newer click, leaves the newer word alone.
        tabs.hand("pear", now: start)
        tabs.failed("apple")
        #expect(tabs.take(now: start) == "pear")
    }

    @Test func aWordPastTheBoundIsDropped() {
        let tabs = NewTabLookups()
        tabs.hand("apple", now: start)
        #expect(tabs.take(now: start + NewTabLookups.bound + .milliseconds(1)) == nil)
        #expect(tabs.take(now: start) == nil, "dropped, not kept for later")
    }
}

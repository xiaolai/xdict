import Testing
@testable import XDictUI

/// **A ⌘-clicked word reaches the tab it opened** (parity P47): the word is handed over before the tab's window is
/// made, taken once by the first main window made after it, and never by a later one.
@MainActor
struct WordInNewTabTests {
    @Test func aHandedWordIsTakenOnceByTheNextWindow() {
        let tabs = NewTabLookups()
        #expect(tabs.take() == nil, "a window made by New Tab or at launch looks nothing up")
        tabs.hand("apple")
        tabs.hand("pear")
        #expect(tabs.take() == "pear", "the latest click's word")
        #expect(tabs.take() == nil, "taken once")
    }
}

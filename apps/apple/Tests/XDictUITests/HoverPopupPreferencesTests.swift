import Foundation
import Testing
@testable import XDictUI

/// **The hover popup's own list and order** (owner, 2026-10-29: "鼠标取词 popup 里词典的选择与顺序, 是不是应该在 settings 里
/// 有设置啊？"): its own, not the window's, and total — a dictionary the reader never touched is shown, one they took out
/// stays out, and one the library lost is forgotten without being remembered as removed.
struct HoverPopupPreferencesTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ai.xdict.tests.hoverPopup.\(UUID().uuidString)"))
    }

    @Test func aReaderWhoNeverChoseSeesTheLibraryInItsOrder() throws {
        let defaults = try suite()
        let first = UUID(), second = UUID(), third = UUID()
        #expect(HoverPopupPreferences.ordered([first, second, third], defaults: defaults) == [first, second, third])
    }

    @Test func theChosenOrderIsKeptAndTheRestAreOut() throws {
        let defaults = try suite()
        let first = UUID(), second = UUID(), third = UUID()
        HoverPopupPreferences.set([third, first], available: [first, second, third], defaults: defaults)
        #expect(HoverPopupPreferences.ordered([first, second, third], defaults: defaults) == [third, first])
    }

    /// The case that makes the rule worth two keys: a dictionary imported after the reader chose joins the popup at the
    /// end — Apple's popover would show it — while the one they removed does not come back with it.
    @Test func aNewDictionaryJoinsTheEndAndARemovedOneStaysOut() throws {
        let defaults = try suite()
        let kept = UUID(), removed = UUID(), fresh = UUID()
        HoverPopupPreferences.set([kept], available: [kept, removed], defaults: defaults)
        #expect(HoverPopupPreferences.ordered([kept, removed, fresh], defaults: defaults) == [kept, fresh])
    }

    /// A dictionary the library no longer has is dropped, and is not recorded as one the reader removed: importing it
    /// again shows it.
    @Test func anIdTheLibraryLostIsForgotten() throws {
        let defaults = try suite()
        let here = UUID(), gone = UUID()
        HoverPopupPreferences.set([gone, here], available: [here, gone], defaults: defaults)
        #expect(HoverPopupPreferences.ordered([here], defaults: defaults) == [here])
        #expect(HoverPopupPreferences.ordered([here, gone], defaults: defaults) == [gone, here])
    }

    /// **A dictionary that is merely disabled keeps its place and its exclusion** (audit 2026-10-29): the sheet saves
    /// from the enabled set, and rebuilding both lists from it alone brought a removed dictionary back on being
    /// enabled again.
    @Test func aDisabledDictionaryKeepsWhatItHad() throws {
        let defaults = try suite()
        let kept = UUID(), off = UUID()
        HoverPopupPreferences.set([kept], available: [kept, off], defaults: defaults)
        // The reader disables `off` in the library, then edits the popup again: only `kept` is on offer.
        HoverPopupPreferences.set([kept], available: [kept], defaults: defaults)
        #expect(HoverPopupPreferences.ordered([kept, off], defaults: defaults) == [kept], "a disabled exclusion was erased")
    }

    @Test func aRepeatedOrUnknownIdCountsOnceAndNothingElse() throws {
        let defaults = try suite()
        let first = UUID(), second = UUID(), stranger = UUID()
        defaults.set([second.uuidString, stranger.uuidString, second.uuidString], forKey: HoverPopupPreferences.orderKey)
        #expect(HoverPopupPreferences.ordered([first, second], defaults: defaults) == [second, first])
        HoverPopupPreferences.set([second, stranger, second], available: [first, second], defaults: defaults)
        #expect(HoverPopupPreferences.ordered([first, second], defaults: defaults) == [second])
    }
}

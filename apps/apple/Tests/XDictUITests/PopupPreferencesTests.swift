import Foundation
import Testing
@testable import XDictUI

/// **The lookup popup's own list and order, and hover's own** (owner, 2026-10-29: "鼠标取词 popup 里词典的选择与顺序, 是不是
/// 应该在 settings 里有设置啊？"; owner, 2026-10-30: "hover's own order (default to inherite from dictionary order, and users
/// can change it for popup)"). Each list is total — a dictionary the reader never touched is shown, one they took out
/// stays out, and one the library lost is forgotten without being remembered as removed — and the two never touch.
struct PopupPreferencesTests {
    private func suite() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ai.xdict.tests.popupPreferences.\(UUID().uuidString)"))
    }

    @Test func aReaderWhoNeverChoseSeesTheLibraryInItsOrder() throws {
        let defaults = try suite()
        let first = UUID(), second = UUID(), third = UUID()
        #expect(PopupPreferences.ordered([first, second, third], defaults: defaults) == [first, second, third])
        #expect(PopupPreferences.ordered([first, second, third], list: .hover, defaults: defaults) == [first, second, third],
                "hover did not follow the dictionaries' order before the reader chose one")
    }

    @Test func theChosenOrderIsKeptAndTheRestAreOut() throws {
        let defaults = try suite()
        let first = UUID(), second = UUID(), third = UUID()
        PopupPreferences.set([third, first], available: [first, second, third], defaults: defaults)
        #expect(PopupPreferences.ordered([first, second, third], defaults: defaults) == [third, first])
    }

    /// **The point of the split** (owner, 2026-10-30): a reader who orders the popup does not thereby reorder hover, and
    /// one who puts a thesaurus last for hover does not take it out of the popup.
    @Test func theTwoListsAreIndependent() throws {
        let defaults = try suite()
        let first = UUID(), second = UUID(), third = UUID()
        PopupPreferences.set([third, first], available: [first, second, third], list: .popup, defaults: defaults)
        #expect(PopupPreferences.ordered([first, second, third], list: .hover, defaults: defaults) == [first, second, third],
                "the popup's order reached hover")
        PopupPreferences.set([third], available: [first, second, third], list: .hover, defaults: defaults)
        #expect(PopupPreferences.ordered([first, second, third], list: .hover, defaults: defaults) == [third])
        #expect(PopupPreferences.ordered([first, second, third], list: .popup, defaults: defaults) == [third, first],
                "hover's list reached the popup")
    }

    /// The case that makes the rule worth two keys: a dictionary imported after the reader chose joins the list at the
    /// end — Apple's popover would show it — while the one they removed does not come back with it.
    @Test func aNewDictionaryJoinsTheEndAndARemovedOneStaysOut() throws {
        let defaults = try suite()
        let kept = UUID(), removed = UUID(), fresh = UUID()
        PopupPreferences.set([kept], available: [kept, removed], defaults: defaults)
        #expect(PopupPreferences.ordered([kept, removed, fresh], defaults: defaults) == [kept, fresh])
    }

    /// A dictionary the library no longer has is dropped, and is not recorded as one the reader removed: importing it
    /// again shows it.
    @Test func anIdTheLibraryLostIsForgotten() throws {
        let defaults = try suite()
        let here = UUID(), gone = UUID()
        PopupPreferences.set([gone, here], available: [here, gone], defaults: defaults)
        #expect(PopupPreferences.ordered([here], defaults: defaults) == [here])
        #expect(PopupPreferences.ordered([here, gone], defaults: defaults) == [gone, here])
    }

    /// **A dictionary that is merely disabled keeps its place and its exclusion** (audit 2026-10-29): the sheet saves
    /// from the enabled set, and rebuilding both lists from it alone brought a removed dictionary back on being
    /// enabled again.
    @Test func aDisabledDictionaryKeepsWhatItHad() throws {
        let defaults = try suite()
        let kept = UUID(), off = UUID()
        PopupPreferences.set([kept], available: [kept, off], defaults: defaults)
        // The reader disables `off` in the library, then edits the popup again: only `kept` is on offer.
        PopupPreferences.set([kept], available: [kept], defaults: defaults)
        #expect(PopupPreferences.ordered([kept, off], defaults: defaults) == [kept], "a disabled exclusion was erased")
    }

    @Test func aRepeatedOrUnknownIdCountsOnceAndNothingElse() throws {
        let defaults = try suite()
        let first = UUID(), second = UUID(), stranger = UUID()
        defaults.set([second.uuidString, stranger.uuidString, second.uuidString], forKey: PopupPreferences.orderKey)
        #expect(PopupPreferences.ordered([first, second], defaults: defaults) == [second, first])
        PopupPreferences.set([second, stranger, second], available: [first, second], defaults: defaults)
        #expect(PopupPreferences.ordered([first, second], defaults: defaults) == [second])
    }

    /// **The saved list is the one that was edited**: hover's keys are its own, and the popup's stay where readers' lists
    /// have lived since 2026-10-29.
    @Test func eachListSavesUnderItsOwnKeys() throws {
        let defaults = try suite()
        let first = UUID(), second = UUID()
        PopupPreferences.set([second, first], available: [first, second], list: .hover, defaults: defaults)
        #expect(defaults.stringArray(forKey: "hover.order") == [second.uuidString, first.uuidString])
        #expect(defaults.stringArray(forKey: "hoverPopup.order") == nil, "hover's list was written over the popup's")
        PopupPreferences.set([first, second], available: [first, second], list: .popup, defaults: defaults)
        #expect(defaults.stringArray(forKey: "hoverPopup.order") == [first.uuidString, second.uuidString])
        #expect(defaults.stringArray(forKey: "hover.order") == [second.uuidString, first.uuidString],
                "the popup's list was written over hover's")
    }
}

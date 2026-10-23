import Foundation
import Testing
@testable import XDictEntryView

struct ComfortableWidthTests {
    @Test func widthPreferenceDefaultsToFullAndPersistsTheReadersChoice() throws {
        let suite = "xdict-width-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EntryPreferences(defaults: defaults)
        #expect(!preferences.comfortableWidth())
        defaults.set(true, forKey: EntryPreferences.comfortableWidthKey)
        #expect(preferences.comfortableWidth())
        defaults.set(false, forKey: EntryPreferences.comfortableWidthKey)
        #expect(!preferences.comfortableWidth())
    }

    @Test func widthChoiceAppliesOnlyToTheMainReadingStyle() {
        let comfortable = EntryReadingFrame.all.with(comfortableWidth: true)
        #expect(comfortable.contains(.comfortable))
        #expect(!comfortable.with(comfortableWidth: false).contains(.comfortable))
        #expect(!EntryReadingFrame.all.union(.panel).with(comfortableWidth: true).contains(.comfortable))
        #expect(!EntryReadingFrame.minimal.with(comfortableWidth: true).contains(.comfortable))
        #expect(!comfortable.applied(originalStyle: true).contains(.comfortable))
    }
}

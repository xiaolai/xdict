import Foundation
import Testing
import XDictContract
@testable import XDictLibrary

/// **What a dictionary's reading choices are kept under** (ADR-0002): its lineage, never its path; an entry that has
/// none yet (not imported) its own id. The Library's details and the search read the same key.
struct PreferencesKeyTests {
    @Test func theKeyIsTheLineageElseTheEntrysId() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        var entry = LibraryEntry(id: id, root: StoredLocation(bookmark: Data([4]), path: "/x"), files: [],
                                 languages: Languages(proposal: LanguageProposal.from(fileName: "a")))
        #expect(entry.preferencesKey == "00000000-0000-0000-0000-000000000001")
        entry.lineage = LineageId(rawValue: "lineage-x")
        #expect(entry.preferencesKey == "lineage-x")
    }
}

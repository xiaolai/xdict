import Foundation
import Testing
import XDictClient
import XDictContract
import XDictEntryView
import XDictLibrary
import XDictSearch

/// **A dictionary's display options, from the service to the entry view** (ADR-0013 decisions 4, 5 and 6): the view's
/// content asks the contract's `displayOptions` for the dictionary it is bound to and takes only what has the
/// catalogue's shape; the reader's choices are kept under the lineage (`LibraryEntry.preferencesKey`), so a join, its
/// Undo and a split move between records without deleting any.
struct DisplayOptionsContentTests {
    static let pronunciation = DisplayOption(id: "pronunciation", attribute: "data-xdict-opt-pronunciation",
                                             values: ["respell", "ipa", "both"], defaultValue: "ipa")

    @Test func theViewsContentAsksTheServiceForTheBoundDictionary() async throws {
        let (content, backend) = try await ServiceEntryContentTests.content { operation in
            guard case .displayOptions = operation else { return .failure(.wire(.interrupted)) }
            return .success(Delivered(answer: .displayOptions(DisplayOptions(
                version: 1, options: [Self.pronunciation], css: ".a { display: none }")), payload: nil))
        }
        let options = try await content.displayOptions()
        #expect(await backend.requests == [.displayOptions(dict: ServiceEntryContentTests.handle)])
        #expect(options.options.map(\.id) == ["pronunciation"])
        #expect(options.options.first?.defaultValue == "ipa")
        #expect(options.css == ".a { display: none }")
    }

    /// An answer holding an option outside the catalogue's shape is refused whole, loudly (the pane records it and
    /// shows the entry as the dictionary wrote it): its attribute and values would be written into a page.
    @Test func anOptionOutsideTheCataloguesShapeIsRefused() async throws {
        let forged = DisplayOption(id: "x", attribute: "data-xdict-opt-y", values: ["a"], defaultValue: "a")
        let (content, _) = try await ServiceEntryContentTests.content { _ in
            .success(Delivered(answer: .displayOptions(DisplayOptions(version: 1, options: [Self.pronunciation, forged],
                                                                      css: "")), payload: nil))
        }
        await #expect(throws: (any Error).self) { try await content.displayOptions() }
    }

    @Test func aFailureIsThrown() async throws {
        let (content, _) = try await ServiceEntryContentTests.content { _ in .failure(.wire(.interrupted)) }
        await #expect(throws: (any Error).self) { try await content.displayOptions() }
    }

    // MARK: - d.5: join, Undo, split

    static func entry(lineage: String) throws -> LibraryEntry {
        var entry = LibraryEntry(id: try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")),
                                 root: StoredLocation(bookmark: Data([1]), path: "/x"), files: [],
                                 languages: Languages(proposal: LanguageProposal.from(fileName: "a")))
        entry.lineage = LineageId(rawValue: lineage)
        return entry
    }

    /// A changed edition starts on the lineage its import minted; joined, it reads the destination lineage's choices
    /// and the minted lineage's record stays; Undo reads the minted lineage's again; a split onto a fresh lineage
    /// starts at the edition's defaults.
    @Test func choicesFollowTheLineageThroughJoinUndoAndSplit() throws {
        let suite = "xdict-display-lineage-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EntryPreferences(defaults: defaults)
        let option = try #require(EntryDisplayOption(id: "pronunciation", attribute: "data-xdict-opt-pronunciation",
                                                     values: ["respell", "ipa", "both"], defaultValue: "ipa"))
        var entry = try Self.entry(lineage: "lineage-earlier")
        preferences.setDisplayChoice("respell", option: "pronunciation", for: entry.preferencesKey)

        // The rewritten file: a minted lineage, where the reader chose "both" before answering the question.
        entry.lineage = LineageId(rawValue: "lineage-minted")
        preferences.setDisplayChoice("both", option: "pronunciation", for: entry.preferencesKey)
        #expect(preferences.displayChoice(option, for: entry.preferencesKey) == "both")

        // Joined (`Library.acceptJoin` sets the lineage it had): the destination's choice, the minted record kept.
        entry.lineage = LineageId(rawValue: "lineage-earlier")
        #expect(preferences.displayChoice(option, for: entry.preferencesKey) == "respell")
        #expect(preferences.storedDisplayChoice("pronunciation", for: "lineage-minted") == "both", "a join deleted a record")

        // Undone (`Library.undoJoin` restores the minted lineage): the former choice is back.
        entry.lineage = LineageId(rawValue: "lineage-minted")
        #expect(preferences.displayChoice(option, for: entry.preferencesKey) == "both")
        #expect(preferences.storedDisplayChoice("pronunciation", for: "lineage-earlier") == "respell")

        // Split onto a lineage of its own: the edition's default, nothing copied.
        entry.lineage = LineageId(rawValue: "lineage-split")
        #expect(preferences.storedDisplayChoice("pronunciation", for: entry.preferencesKey) == nil)
        #expect(preferences.displayChoice(option, for: entry.preferencesKey) == "ipa")
    }
}

import Foundation
import Testing
import XDictCapture
import XDictCaptureMac
@testable import XDict

/// **The diagnostics bridge keeps the reader's words out of the log** (audit 2026-10-29 finding 1): every lookup event's
/// fields went through `String(describing:)` into `Diagnostics.record`, so the Service's text, the shown and expanded
/// queries and the entry key were written whatever "Include the words I look up" said. The bridge now redacts the fields
/// that carry text, and a selection's outcome is described as metadata instead of having its own description written.
struct LookupLoggingTests {
    private func diagnostics(includeText: Bool) throws -> Diagnostics {
        let suite = try #require(UserDefaults(suiteName: "ai.xdict.logging.\(UUID().uuidString)"))
        suite.set(includeText, forKey: Diagnostics.includeTextKey)
        return Diagnostics(defaults: suite, directory: FileManager.default.temporaryDirectory
            .appending(path: "logging-\(UUID().uuidString)"))
    }

    /// Kinds, counts and names pass; the fields a reader's words travel in are withheld — by name, in one place.
    @Test func theWordsAreWithheldWithoutTheReadersSwitch() throws {
        let log = try diagnostics(includeText: false)
        let fields = LookupAnywhere.logged(["text": "inspection", "query": "inspection", "key": "inspect",
                                            "request": 7, "source": "service"], diagnostics: log)
        #expect(fields["request"] == "7")
        #expect(fields["source"] == "service")
        #expect(fields["text"] == "<withheld: 10 chars>")
        #expect(fields["query"] == "<withheld: 10 chars>")
        #expect(fields["key"] == "<withheld: 7 chars>")
        #expect(!fields.values.contains("inspection"), "the reader's word reached the log with the switch off")
    }

    @Test func theReadersSwitchPutsTheirWordsBackIn() throws {
        let log = try diagnostics(includeText: true)
        #expect(LookupAnywhere.logged(["query": "inspection"], diagnostics: log)["query"] == "inspection")
    }

    /// Its `String(describing:)` carried the selection and the sentence around it; the log gets the case, the app and
    /// the counts.
    @Test func aSelectionOutcomeIsDescribedWithoutItsText() {
        let app = FrontApp(pid: 42, name: "Notes", bundleID: "com.apple.Notes")
        let selected = SelectionOutcome.selected(
            SelectedText(text: "inspection", app: app, acquisition: .textRange), box: nil)
        let described = LookupAnywhere.lookupDescription(selected)
        #expect(described == "selected(app=com.apple.Notes chars=10 box=no)")
        #expect(!described.contains("inspection"))
        #expect(LookupAnywhere.lookupDescription(.nothing(.noWord(app: "com.apple.Notes"))) == "noWord(com.apple.Notes)")
        #expect(LookupAnywhere.lookupDescription(.nothing(.tooLong(app: "com.apple.Notes", characters: 400)))
                == "tooLong(com.apple.Notes chars=400)")
        #expect(LookupAnywhere.lookupDescription(nil) == "none")
    }
}

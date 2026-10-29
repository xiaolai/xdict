import Foundation
import Testing
@testable import XDictEntryView

/// **The entry's language on its document** (owner, 2026-10-29; `dev-docs/note-cjk-typography-2026-10-29.md`): the
/// library's own code, set before the reading style is applied so `:lang(zh)` can give Chinese text its leading. The code
/// is never spliced into the script, and a code that is not one leaves the document alone.
struct EntryLanguageTests {
    @Test func theCodeIsSetOnTheRootAndNothingElse() {
        #expect(EntryScripts.language("zh-Hans") == #"document.documentElement.lang="zh-Hans";"#)
        #expect(EntryScripts.language("en") == #"document.documentElement.lang="en";"#)
    }

    /// A language code is letters, digits and hyphens; anything else — a quote, a semicolon, a script — is not one.
    @Test func aCodeThatIsNotOneIsRefused() {
        #expect(EntryScripts.language(nil) == nil)
        #expect(EntryScripts.language("") == nil)
        #expect(EntryScripts.language("zh\";alert(1);\"") == nil)
        #expect(EntryScripts.language("zh Hans") == nil)
        #expect(EntryScripts.language("日本語") == nil)
    }

    /// Installed first, before the appearance script that applies the style: the language is news the CSS reads once.
    @Test func theLanguageScriptIsInstalledFirst() {
        let scripts = EntryScripts.installed(.light, frame: .all, language: "zh-Hans")
        #expect(scripts.first == #"document.documentElement.lang="zh-Hans";"#)
        #expect(!EntryScripts.installed(.light, frame: .all).contains { $0.contains("documentElement.lang") },
                "a dictionary that declares nothing sets nothing")
    }

    /// **The reading style's Chinese leading is keyed on that language**, and on nothing else: the Latin page keeps 1.4.
    @Test func theStyleGivesChineseItsOwnLeading() throws {
        // The package root: three folders up from Tests/XDictEntryViewTests/EntryLanguageTests.swift.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = root.appending(path: "Sources/XDictEntryView/Style/type.css")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("html:lang(zh){--xdict-leading:1.6}"))
        #expect(!text.contains("1.6") || text.contains("html:lang(zh)"), "a leading raised for everyone would move every Latin page")
    }
}

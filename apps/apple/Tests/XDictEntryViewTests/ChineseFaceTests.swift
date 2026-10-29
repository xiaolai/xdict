import Foundation
import Testing
import WebKit
@testable import XDictEntryView

/// **The reader's Chinese face** (owner, 2026-10-29; `dev-docs/note-cjk-typography-2026-10-29.md`): the face the reader chooses
/// is put on the document as `--xdict-font-cjk`, and a name the Mac cannot draw is never put there — an unknown name
/// resolves to Helvetica, which has no Han at all.
struct ChineseFaceTests {
    @Test func aFamilyIsJudgedByWhatItResolvesTo() {
        #expect(EntryChineseFace.isInstalled("Songti SC"))
        #expect(EntryChineseFace.isInstalled("PingFang SC"))
        // Measured: not installed on this Mac, and the system answers with Helvetica — which is not the family asked for.
        #expect(!EntryChineseFace.isInstalled("Hiragino Sans CNS"))
        #expect(!EntryChineseFace.isInstalled("No Such Face At All"))
    }

    /// The stack names the chosen family first and then keeps every family the reading style would have used, so a
    /// character the chosen face lacks still finds a Chinese face.
    @Test func theStackKeepsTheStylesOwnFacesBehindTheChoice() {
        let stack = EntryChineseFace.pingfang.stack
        #expect(stack.hasPrefix("\"PingFang SC\""))
        #expect(stack.contains("Songti SC"), "the style's own face must stay behind the choice: \(stack)")
    }

    @Test func theScriptSetsThePropertyOnTheRoot() {
        let script = EntryScripts.chineseFace(.pingfang)
        #expect(script?.contains("--xdict-font-cjk") == true)
        #expect(script?.contains("PingFang SC") == true)
    }

    /// The style's own face needs no override, and nothing is written when the reader never chose.
    @Test func theStylesOwnFaceIsLeftAlone() {
        #expect(EntryScripts.chineseFace(.songti) == nil)
        #expect(EntryScripts.chineseFace(nil) == nil)
    }

    /// **The wiring, not only the pieces**: a window whose preferences say PingFang installs that script on its pane,
    /// at document start, so the reader's face is on the document before the style is.
    @MainActor
    @Test func theChosenFaceReachesThePanesScripts() async throws {
        let suite = try #require(UserDefaults(suiteName: "xdict.face.\(UUID().uuidString)"))
        let preferences = EntryPreferences(defaults: suite)
        preferences.setChineseFace(.pingfang)
        var environment = EntryEnvironment(preferences: preferences)
        environment.ruleListDirectory = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString)")
        let controller = EntryViewController(environment: environment)
        let content = FakeContent("alpha")
        content.documents["alpha"] = EntryDocument(html: Data("<b>alpha</b>".utf8), policy: "default-src 'none'")
        _ = await controller.show(EntryReference(key: "alpha"), from: content)
        defer { controller.closeEntry() }
        let sources = controller.webView?.configuration.userContentController.userScripts.map(\.source) ?? []
        #expect(sources.contains { $0.contains("--xdict-font-cjk") && $0.contains("PingFang SC") },
                "the pane did not get the reader's Chinese face: \(sources.filter { $0.contains("font-cjk") })")
    }

    @Test func theChoiceIsKeptAndAForeignValueReadsAsTheStylesOwn() throws {
        let defaults = try #require(UserDefaults(suiteName: "ai.xdict.tests.face.\(UUID().uuidString)"))
        let preferences = EntryPreferences(defaults: defaults)
        #expect(preferences.chineseFace() == .songti, "the style's own face is the default")
        preferences.setChineseFace(.kaiti)
        #expect(EntryPreferences(defaults: defaults).chineseFace() == .kaiti)
        defaults.set("hello", forKey: EntryPreferences.chineseFaceKey)
        #expect(EntryPreferences(defaults: defaults).chineseFace() == .songti)
    }
}

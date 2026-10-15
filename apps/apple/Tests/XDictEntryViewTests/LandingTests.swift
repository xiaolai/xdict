import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import XDictEntryView

/// **Where an entry lands, and what the keyboard reaches in it** (plan-macos-v1 WI-6: Back restores the scroll a place
/// was left at, a link's anchor is where its entry opens, I8; Tab reaches the entry's links, R10). The scripts run in
/// the shell's own world on the E2E Mac; here they must parse, take their place as an argument rather than as text, and
/// neither request anything nor move the document.
struct LandingTests {
    @Test func theTopNeedsNoScript() {
        #expect(EntryScripts.landing(.top) == nil)
    }

    @Test func anOffsetAndAnAnchorAreArgumentsOfAScriptThatParses() throws {
        let context = try #require(JSContext())
        for landing: EntryLanding in [.offset(1_234.5), .anchor("sense\"2</script>")] {
            let script = try #require(EntryScripts.landing(landing))
            context.setObject(script.body, forKeyedSubscript: "source" as NSString)
            let parsed = context.evaluateScript("try { new Function('y', 'a', source); 'ok' } catch (e) { String(e) }")
            #expect(parsed?.toString() == "ok", "\(landing)")
            #expect(!script.body.contains("1234") && !script.body.contains("sense"), "the place is spliced into the script")
        }
        #expect(EntryScripts.landing(.offset(80))?.arguments["y"] as? Double == 80)
        #expect(EntryScripts.landing(.anchor("s2"))?.arguments["a"] as? String == "s2")
        context.setObject(EntryScripts.scrollOffset, forKeyedSubscript: "source" as NSString)
        #expect(context.evaluateScript("try { new Function(source); 'ok' } catch (e) { String(e) }")?.toString() == "ok")
    }

    @Test func noLandingScriptRequestsAnythingOrChangesTheURL() {
        let all = [EntryScripts.landing(.offset(1))?.body, EntryScripts.landing(.anchor("a"))?.body,
                   EntryScripts.scrollOffset].compactMap(\.self).joined(separator: "\n")
        for word in ["fetch(", "XMLHttpRequest", "location", "window.open", ".src =", ".href =", "hash"] {
            #expect(!all.contains(word), "a landing script uses \(word)")
        }
    }

    /// R10: with the switch on, Tab moves through the entry's links, so the keyboard can follow one.
    @Test @MainActor func tabReachesTheEntrysLinks() {
        let preferences = WKPreferences()
        EntryPane.configure(preferences, confinement: .production)
        #expect(preferences.tabFocusesLinks)
        #expect(!preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(!preferences.isElementFullscreenEnabled)
    }
}

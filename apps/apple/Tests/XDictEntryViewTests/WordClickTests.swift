import Foundation
import JavaScriptCore
import Testing
@testable import XDictEntryView

/// **⌘-click on a word opens its lookup in a new tab** (parity P47; owner, 2026-10-18: a plain click does nothing new,
/// readers misclick). The word is the segmenter's word under the caret, trimmed of punctuation; only the reader's own
/// single ⌘-click with nothing selected, outside links and controls, asks; and the native side takes from the page
/// only a bounded word with no control character, since the page is untrusted.
struct WordClickTests {
    static func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
        context.evaluateScript(EntryScripts.wordClicksCore)
        context.evaluateScript("var seg = new Intl.Segmenter('en', { granularity: 'word' });")
        return context
    }

    static func at(_ context: JSContext, _ text: String, _ offset: Int) -> String {
        context.setObject(text, forKeyedSubscript: "t" as NSString)
        let hit = context.evaluateScript("var h = XDictWordCore.at(t, \(offset), seg); h ? h.word : 'none'")
        return hit?.toString() ?? "?"
    }

    @Test func theWordUnderTheCaretIsTheSegmentersWordTrimmed() throws {
        let context = try Self.context()
        #expect(Self.at(context, "the apple, red", 5) == "apple")
        #expect(Self.at(context, "the apple, red", 9) == "apple", "just after its last letter")
        #expect(Self.at(context, "the apple, red", 4) == "apple")
        #expect(Self.at(context, "café crème", 2) == "café", "an accented word stays whole")
        #expect(Self.at(context, "don't", 1) == "don't")
        #expect(Self.at(context, "“quoted”", 3) == "quoted")
        #expect(Self.at(context, "我喜欢苹果", 4) == "苹果", "a CJK run gives its word")
        #expect(Self.at(context, "a  —  b", 3) == "none", "punctuation and space are no word")
        #expect(Self.at(context, "   ", 1) == "none")
        #expect(Self.at(context, "", 0) == "none")
        #expect(Self.at(context, "word", 9) == "none", "an offset past the text")
        #expect(Self.at(context, String(repeating: "a", count: 65), 3) == "none", "longer than the bound")
        #expect(Self.at(context, String(repeating: "a", count: 64), 3) == String(repeating: "a", count: 64))
    }

    @Test func onlyTheReadersSingleCommandClickWithNothingSelectedAsks() throws {
        let context = try Self.context()
        func allowed(_ event: String, selected: Bool = false) -> Bool {
            context.evaluateScript("XDictWordCore.allowed(\(event), \(selected))")?.toBool() ?? true
        }
        let command = "isTrusted: true, button: 0, detail: 1, metaKey: true"
        #expect(allowed("{ \(command) }"))
        #expect(!allowed("{ isTrusted: true, button: 0, detail: 1, metaKey: false }"), "a plain click looks nothing up")
        #expect(!allowed("{ isTrusted: false, button: 0, detail: 1, metaKey: true }"), "a script's click is not the reader")
        #expect(!allowed("{ \(command) }", selected: true), "a selection")
        #expect(!allowed("{ isTrusted: true, button: 0, detail: 2, metaKey: true }"), "a double click")
        #expect(!allowed("{ isTrusted: true, button: 2, detail: 1, metaKey: true }"))
        #expect(!allowed("{ \(command), shiftKey: true }"))
        #expect(!allowed("{ \(command), altKey: true }"))
        #expect(!allowed("{ \(command), ctrlKey: true }"))
        #expect(!allowed("{ \(command), defaultPrevented: true }"), "the page took the click")
        #expect(!allowed("null"))
    }

    @Test func theDOMScriptPostsOnlyAWordAndSkipsLinksAndControls() {
        let dom = EntryScripts.wordClicksDOM
        #expect(dom.contains("kind: 'word', word: word }"))
        #expect(dom.contains("XDictWordCore.allowed(e, selected())"))
        for control in ["a[href]", "button", "input", "[data-xdict-control]", "[role=link]", "[contenteditable]"] {
            #expect(dom.contains(control), "\(control) is not skipped")
        }
        let installed = EntryScripts.installed(.light, frame: .all)
        #expect(installed.contains(EntryScripts.wordClicksCore) && installed.contains(EntryScripts.wordClicksDOM))
    }

    @Test func aWordMessageIsTakenOnlyWhenItIsABoundedPlainWord() {
        #expect(EntryWordClick(message: ["kind": "word", "word": "apple"])?.word == "apple")
        #expect(EntryWordClick(message: ["kind": "word", "word": "苹果"])?.word == "苹果")
        #expect(EntryWordClick(message: ["kind": "word", "word": String(repeating: "é", count: 64)]) != nil)
        let refused: [Any] = [
            "apple", ["kind": "word"], ["kind": "blocked-image", "word": "apple"], ["kind": "word", "word": 3],
            ["kind": "word", "word": ""], ["kind": "word", "word": "  "], ["kind": "word", "word": "two words"],
            ["kind": "word", "word": "line\nbreak"], ["kind": "word", "word": "nul\u{0}"], ["kind": "word", "word": "bell\u{7}"],
            ["kind": "word", "word": "para\u{2029}"], ["kind": "word", "word": String(repeating: "a", count: 65)],
            ["kind": "word", "word": "apple", "newTab": false],
        ]
        for body in refused { #expect(EntryWordClick(message: body) == nil, "\(body)") }
    }

    @Test func theHandlerTakesAWordOnlyFromTheShellsWorld() throws {
        let body: [String: Any] = ["kind": "word", "word": "apple"]
        #expect(EntryPane.message(body, fromShellsWorld: true) == .word(try #require(EntryWordClick(message: body))))
        #expect(EntryPane.message(body, fromShellsWorld: false) == .refused)
        #expect(EntryPane.message(["kind": "word", "word": "a\u{1}"], fromShellsWorld: true) == .refused)
        #expect(EntryPane.message(["kind": "blocked-image", "url": "x"], fromShellsWorld: true) == .blockedImage("x"))
    }
}

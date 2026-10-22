import Foundation
import JavaScriptCore
import Testing
@testable import XDictEntryView

/// **A click on a sense names only its ordinal** (plan-explain-sense WI-5; ADR-0029 d.2, d.6): the page is untrusted,
/// so the script sends no text at all; the native side takes a bounded integer from the shell's world and nothing else.
/// A forged or duplicated `data-xdict-sense` names no sense, and the reader's click is a plain single click — ⌘-click
/// stays the word lookup's.
struct SenseClickTests {
    static func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("JS: \(exception?.toString() ?? "?")") }
        context.evaluateScript(EntryScripts.senseClicksCore)
        return context
    }

    static func valid(_ context: JSContext, _ raw: String) -> Int? {
        context.setObject(raw, forKeyedSubscript: "r" as NSString)
        guard let value = context.evaluateScript("XDictSenseCore.valid(r)"), !value.isNull, !value.isUndefined,
              let number = value.toNumber() else { return nil }
        return number.intValue
    }

    @Test func anOrdinalIsPlainDigitsWithinTheBound() throws {
        let context = try Self.context()
        #expect(Self.valid(context, "1") == 1)
        #expect(Self.valid(context, "375") == 375)
        #expect(Self.valid(context, "1000000") == 1_000_000)
        for refused in ["0", "01", "-1", "+1", "1.5", "1e3", " 1", "1 ", "", "1x", "1000001", "9999999", "٣"] {
            #expect(Self.valid(context, refused) == nil, "\(refused) named a sense")
        }
    }

    @Test func onlyOneElementMayCarryTheOrdinal() throws {
        let context = try Self.context()
        #expect(context.evaluateScript("XDictSenseCore.unique(1)")?.toBool() == true)
        #expect(context.evaluateScript("XDictSenseCore.unique(0)")?.toBool() == false)
        #expect(context.evaluateScript("XDictSenseCore.unique(2)")?.toBool() == false)
    }

    @Test func onlyTheReadersPlainSingleClickSelects() throws {
        let context = try Self.context()
        func allowed(_ event: String, selected: Bool = false) -> Bool {
            context.evaluateScript("XDictSenseCore.allowed(\(event), \(selected))")?.toBool() ?? true
        }
        let plain = "isTrusted: true, button: 0, detail: 1, metaKey: false"
        #expect(allowed("{ \(plain) }"))
        #expect(!allowed("{ isTrusted: false, button: 0, detail: 1 }"), "a script's click is not the reader")
        #expect(!allowed("{ \(plain), metaKey: true }"), "⌘-click is the word lookup's")
        #expect(!allowed("{ \(plain), shiftKey: true }"))
        #expect(!allowed("{ \(plain), altKey: true }"))
        #expect(!allowed("{ \(plain), ctrlKey: true }"))
        #expect(!allowed("{ isTrusted: true, button: 0, detail: 2 }"), "a double click")
        #expect(!allowed("{ isTrusted: true, button: 2, detail: 1 }"))
        #expect(!allowed("{ \(plain) }", selected: true), "a selection")
        #expect(!allowed("{ \(plain), defaultPrevented: true }"), "the page took the click")
        #expect(!allowed("null"))
    }

    @Test func theDOMScriptSendsOnlyTheOrdinalAndSkipsLinksAndControls() {
        let dom = EntryScripts.senseClicksDOM
        #expect(dom.contains("kind: 'sense', id: id }"))
        #expect(dom.contains("t.closest('[data-xdict-sense]')"))
        #expect(dom.contains("XDictSenseCore.unique(document.querySelectorAll"))
        for control in ["a[href]", "button", "input", "[data-xdict-control]", "[role=link]", "[contenteditable]"] {
            #expect(dom.contains(control), "\(control) is not skipped")
        }
        #expect(!dom.contains("innerText") && !dom.contains("textContent"), "the page's text is never sent")
        let installed = EntryScripts.installed(.light, frame: .all)
        #expect(installed.contains(EntryScripts.senseClicksCore) && installed.contains(EntryScripts.senseClicksDOM))
    }

    @Test func aSenseMessageIsTakenOnlyAsOneBoundedInteger() {
        #expect(EntrySenseClick(message: ["kind": "sense", "id": 1])?.id == 1)
        #expect(EntrySenseClick(message: ["kind": "sense", "id": NSNumber(value: 375)])?.id == 375)
        #expect(EntrySenseClick(message: ["kind": "sense", "id": NSNumber(value: 1_000_000)])?.id == 1_000_000)
        let refused: [Any] = [
            "3", ["kind": "sense"], ["kind": "word", "id": 1], ["kind": "sense", "id": "3"],
            ["kind": "sense", "id": NSNumber(value: 1.5)], ["kind": "sense", "id": NSNumber(value: 0)],
            ["kind": "sense", "id": NSNumber(value: -1)], ["kind": "sense", "id": NSNumber(value: 1_000_001)],
            ["kind": "sense", "id": NSNumber(value: true)], ["kind": "sense", "id": 3, "text": "forged"],
            ["kind": "sense", "id": NSNull()],
        ]
        for body in refused {
            #expect(EntrySenseClick(message: body) == nil, "\(body)")
        }
    }

    /// **A sense message belongs to the document the pane shows**: a stale document's message names another entry, and
    /// an in-page anchor's fragment does not make another document (plan-explain-sense WI-5).
    @Test func onlyTheCurrentDocumentSelects() throws {
        let document = try #require(URL(string: "xdict://d/hold?o=0"))
        let fragment = try #require(URL(string: "xdict://d/hold?o=0#sense-2"))
        let otherKey = try #require(URL(string: "xdict://d/held?o=0"))
        let otherOccurrence = try #require(URL(string: "xdict://d/hold?o=1"))
        #expect(EntryPane.sameDocument(document, document))
        #expect(EntryPane.sameDocument(fragment, document), "an in-page anchor is the same document")
        #expect(!EntryPane.sameDocument(otherKey, document))
        #expect(!EntryPane.sameDocument(otherOccurrence, document))
        #expect(!EntryPane.sameDocument(nil, document))
        #expect(!EntryPane.sameDocument(document, nil))
    }

    @Test func theHandlerTakesASenseOnlyFromTheShellsWorld() throws {
        let body: [String: Any] = ["kind": "sense", "id": 2]
        #expect(EntryPane.message(body, fromShellsWorld: true) == .sense(try #require(EntrySenseClick(message: body))))
        #expect(EntryPane.message(body, fromShellsWorld: false) == .refused)
        #expect(EntryPane.message(["kind": "sense", "id": NSNumber(value: true)], fromShellsWorld: true) == .refused)
    }
}

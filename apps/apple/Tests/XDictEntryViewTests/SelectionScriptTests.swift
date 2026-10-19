import Foundation
import Testing
@testable import XDictEntryView

/// **The selection script against hostile pages, in a real web view** (owner, 2026-10-20: the shortcut, the menu and the
/// Service capture the sentence in XDict's own windows too). `hover-word.js`'s `__xdictSelectionText`, installed as every
/// entry installs it and asked through the shell's own call (`EntryWebView.selectionText`), in the same lab run as the
/// hover pages (`HoverWordScriptTests`). It must hold what the hover script holds: **only shown text**, for the selection
/// and for the text around it; **its own work bounded** — in depth, in nodes walked and in text taken — so a 50 MB node
/// or a flood of elements costs a bounded time; **the page's own changes to built-ins never reach it**; and a selection
/// longer than asked for is said to be, never cut.
extension HoverWordScriptTests {
    /// Selects from the first text node of `#a` at `from` to the first text node of `#b` at `to`.
    static func selecting(_ from: Int, _ to: Int, _ start: String = "t", _ end: String = "t") -> String {
        "var a = document.getElementById('\(start)').firstChild, b = document.getElementById('\(end)').firstChild;"
            + "getSelection().setBaseAndExtent(a, \(from), b, \(to)); return 'selected';"
    }

    static let selectionPages: [Page] = [
        Page(name: "select-plain", body: "<p id=t>An ephemeral beauty. Second sentence here.</p>", target: "t",
             select: selecting(3, 12)),
        // Each page's body its own: the lab's web view did not finish loading a body the same as the page before it.
        Page(name: "select-no-sentence", body: "<p id=t>An ephemeral beauty, never asked around.</p>", target: "t",
             select: selecting(3, 12), sentence: false),
        Page(name: "select-hidden",
             body: "<p id=t>Visible <span style='display:none'>HIDDENDISPLAY</span><span style='opacity:0'>HIDDENOPACITY"
                 + "</span><span style='visibility:hidden'>HIDDENVISIBILITY</span>word <span id=u>here</span> now."
                 + "<script>var SCRIPTTEXT = 1</script></p>",
             target: "t", select: selecting(0, 4, "t", "u")),
        Page(name: "select-across-blocks", body: "<p id=t>One end</p><p id=u>Two start</p>", target: "t",
             select: selecting(4, 3, "t", "u")),
        Page(name: "select-collapsed", body: "<p id=t>An ephemeral beauty.</p>", target: "t", select: selecting(3, 3)),
        Page(name: "select-over", body: "<p id=t>" + String(repeating: "word ", count: 60) + "</p>", target: "t",
             max: 240, select: selecting(0, 300)),
        Page(name: "select-input", body: "<input id=t value='Field words here' style='width:300px'>", target: "t",
             offset: nil, select: "var f = document.getElementById('t'); f.focus(); f.select(); return 'selected';"),
        Page(name: "select-fifty-megabytes",
             body: "<p id=t></p><script>document.getElementById('t').appendChild("
                 + "document.createTextNode('quokka '.repeat(7200000)));</script>",
             target: "t", max: 1_000, select: selecting(3_500_000, 3_500_006)),
        Page(name: "select-flood",
             body: "<p id=b><span id=t>First words</span></p><script>var p = document.getElementById('b');"
                 + "var f = document.createDocumentFragment();"
                 + "for (var i = 0; i < 100000; i++) f.appendChild(document.createElement('span'));"
                 + "var s = document.createElement('span'); s.id = 'u'; s.textContent = 'Last words'; f.appendChild(s);"
                 + "p.appendChild(f);</script>",
             target: "t", select: selecting(0, 4, "t", "u")),
        // Past the script's depth (64), and cheap: a 100,000-deep page costs the lab half its minute to build.
        Page(name: "select-deep", body: deep(100), target: "t", select: selecting(0, 4)),
        Page(name: "select-overrides",
             body: overrides + "<script>window.__xdictSelectionText = function () { return {selected: 'SPOOF', around: null}; };"
                 + "Selection.prototype.getRangeAt = function () { throw new Error('page'); };"
                 + "Document.prototype.getSelection = function () { return null; };"
                 + "Range.prototype.comparePoint = function () { return 0; };</script>"
                 + "<p id=t>Quokka selection probe sentence here.</p>",
             target: "t", select: selecting(0, 6)),
    ]

    private func selection(_ name: String) -> EntrySelectionText? {
        do { return try outcome(name).selection } catch {
            Issue.record(error)
            return .selected("no outcome", around: nil)
        }
    }

    private func around(_ text: String, _ offset: Int, cut: (Bool, Bool) = (false, false)) -> EntryHoverText {
        EntryHoverText(text: text, offset: offset, cutStart: cut.0, cutEnd: cut.1)
    }

    @Test func everySelectionPageAnswersWithinASecond() throws {
        for page in Self.selectionPages {
            let took = try outcome(page.name).milliseconds
            #expect(took < 1_000, "\(page.name): \(took) ms")
        }
    }

    @Test func aSelectionIsReadWithTheTextAroundIt() {
        #expect(selection("select-plain")
                == .selected("ephemeral", around: around("An ephemeral beauty. Second sentence here.", 3)))
    }

    /// The text around it is not asked for where the reader excluded XDict.
    @Test func aSelectionAloneIsReadWhenNoSentenceIsAsked() {
        #expect(selection("select-no-sentence") == .selected("ephemeral", around: nil))
    }

    /// Hidden text inside the selection is not part of it, nor of the text around it.
    @Test func hiddenTextIsNoPartOfTheSelection() {
        #expect(selection("select-hidden") == .selected("Visible word here", around: around("Visible word here now.", 0)))
    }

    /// Two blocks are two lines, and have no one sentence around them.
    @Test func aSelectionAcrossBlocksHasNoSentence() {
        #expect(selection("select-across-blocks") == .selected("end\nTwo", around: nil))
    }

    @Test func nothingSelectedIsNoAnswer() {
        #expect(selection("select-collapsed") == nil)
        #expect(selection("select-input") == nil, "a text field's selection is the field's, not the entry's text")
        #expect(selection("select-deep") == nil, "a selection deeper than the script reads")
    }

    /// A selection longer than asked for is said to be, never cut; so is one the walk cannot finish.
    @Test func aSelectionTooLongIsSaidToBe() {
        #expect(selection("select-over") == .tooLong)
        #expect(selection("select-flood") == .tooLong)
    }

    /// A selection inside one 50 MB text node: the text around it windowed, never the whole node.
    @Test func aSelectionInsideFiftyMegabytesIsWindowed() throws {
        guard case .selected(let selected, let found?) = selection("select-fifty-megabytes") else {
            Issue.record("no selection with text around it")
            return
        }
        #expect(selected == "quokka")
        #expect(found.text.utf16.count <= 1_000 && found.cutStart && found.cutEnd)
        let at = (found.text as NSString).substring(with: NSRange(location: found.offset, length: 6))
        #expect(at == "quokka")
    }

    @Test func thePagesBuiltInsNeverReachTheSelectionScript() {
        #expect(selection("select-overrides")
                == .selected("Quokka", around: around("Quokka selection probe sentence here.", 0)))
    }
}

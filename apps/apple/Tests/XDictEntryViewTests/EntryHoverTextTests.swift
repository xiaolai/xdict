import Foundation
import Testing
@testable import XDictEntryView

/// **Hover over XDict's own entry asks the entry, not Accessibility** (verifier, 2026-10-19: an in-process Accessibility
/// hit test over the entry's web view waits on WebKit, which waits on the main thread). The entry's script runs in the
/// shell's own world and answers the word's block of text around the word; **its reply is data from a page**, so it is
/// taken only in exactly the shape the script writes and within the bound asked for. No web view is made here.
struct EntryHoverTextTests {
    private static func reply(_ text: Any = "Quokka hover probe.", offset: Any = NSNumber(value: 0),
                              cutStart: Any = kCFBooleanFalse as Any, cutEnd: Any = kCFBooleanTrue as Any) -> [String: Any] {
        ["text": text, "offset": offset, "cutStart": cutStart, "cutEnd": cutEnd]
    }

    @Test func theScriptsShapeIsTaken() throws {
        let taken = try #require(EntryHoverText.validated(Self.reply(), maxUTF16: 240))
        #expect(taken == EntryHoverText(text: "Quokka hover probe.", offset: 0, cutStart: false, cutEnd: true))
    }

    /// Red where any part of the reply is taken on trust: a missing or extra key, a wrong type, a number for a flag, a
    /// fractional or out-of-range offset, empty text, or text past the bound asked for.
    @Test func anyOtherReplyIsRefused() {
        var extra = Self.reply()
        extra["html"] = "<b>"
        var missing = Self.reply()
        missing.removeValue(forKey: "cutEnd")
        let refused: [Any?] = [
            nil, "Quokka", [Self.reply()], extra, missing,
            Self.reply(42), Self.reply(""), Self.reply(String(repeating: "a", count: 241)),
            // A pair cut in half, at either end.
            Self.reply(NSString(characters: [0xDC9C, 0x20, 0x61], length: 3)),
            Self.reply(NSString(characters: [0x61, 0x20, 0xD835], length: 3)),
            Self.reply(offset: "0"), Self.reply(offset: NSNumber(value: 1.5)), Self.reply(offset: NSNumber(value: -1)),
            Self.reply(offset: NSNumber(value: 19)), Self.reply(offset: kCFBooleanTrue as Any),
            Self.reply(cutStart: NSNumber(value: 1)), Self.reply(cutEnd: "true"),
        ]
        for reply in refused {
            #expect(EntryHoverText.validated(reply, maxUTF16: 240) == nil, "taken: \(String(describing: reply))")
        }
        #expect(EntryHoverText.validated(Self.reply(), maxUTF16: 0) == nil)
    }

    /// **The script is installed with the entry's others, after the word core it uses**, so the shell's world has it.
    @Test func theHoverScriptIsInstalledAfterTheWordCore() throws {
        let installed = EntryScripts.installed(.light, frame: .all)
        let core = try #require(installed.firstIndex(of: EntryScripts.wordClicksCore))
        let hover = try #require(installed.firstIndex(of: EntryScripts.hoverWord), "the hover script is not installed")
        #expect(core < hover)
    }
}

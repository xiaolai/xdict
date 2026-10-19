import Foundation
import Testing
@testable import XDictEntryView

/// **The lookup shortcut, the menu and the Service over XDict's own entry ask the entry for its selection** (owner,
/// 2026-10-20), never Accessibility, which waits on WebKit while WebKit waits on the main thread. The entry's script runs
/// in the shell's own world; **its reply is data from a page**, taken only in exactly the shapes the script writes —
/// the selection and the text around it, or "longer than asked for" — and within the bound asked for, the text around
/// it holding the selection exactly where it says. No web view is made here.
struct EntrySelectionTextTests {
    private static func around(_ text: Any = "An ephemeral beauty.", offset: Any = NSNumber(value: 3),
                               cutStart: Any = kCFBooleanFalse as Any, cutEnd: Any = kCFBooleanTrue as Any) -> [String: Any] {
        ["text": text, "offset": offset, "cutStart": cutStart, "cutEnd": cutEnd]
    }

    private static func reply(_ selected: Any = "ephemeral", around: Any = Self.around()) -> [String: Any] {
        ["selected": selected, "around": around]
    }

    @Test func theScriptsShapesAreTaken() throws {
        let taken = try #require(EntrySelectionText.validated(Self.reply(), maxUTF16: 240))
        #expect(taken == .selected("ephemeral", around: EntryHoverText(text: "An ephemeral beauty.", offset: 3,
                                                                        cutStart: false, cutEnd: true)))
        #expect(EntrySelectionText.validated(Self.reply(around: NSNull()), maxUTF16: 240) == .selected("ephemeral", around: nil))
        #expect(EntrySelectionText.validated(["over": kCFBooleanTrue as Any], maxUTF16: 240) == .tooLong)
    }

    /// Red where any part of the reply is taken on trust: a missing or extra key, a wrong type, an empty or over-long
    /// selection, a pair cut in half, text around it out of shape, or text around it that does not hold the selection
    /// where it says.
    @Test func anyOtherReplyIsRefused() {
        var extra = Self.reply()
        extra["html"] = "<b>"
        let refused: [Any?] = [
            nil, "ephemeral", [Self.reply()], extra, ["selected": "ephemeral"], ["around": Self.around()],
            Self.reply(42), Self.reply(""), Self.reply(String(repeating: "a", count: 241), around: NSNull()),
            Self.reply(NSString(characters: [0xDC9C, 0x61], length: 2), around: NSNull()),
            Self.reply(around: "An ephemeral beauty."), Self.reply(around: Self.around(offset: NSNumber(value: 1.5))),
            // Not where it says, and running past the end.
            Self.reply(around: Self.around(offset: NSNumber(value: 4))),
            Self.reply("beauty. And", around: Self.around(offset: NSNumber(value: 13))),
            ["over": NSNumber(value: 1)], ["over": kCFBooleanFalse as Any], ["over": kCFBooleanTrue as Any, "selected": "a"],
        ]
        for reply in refused {
            #expect(EntrySelectionText.validated(reply, maxUTF16: 240) == nil, "taken: \(String(describing: reply))")
        }
        #expect(EntrySelectionText.validated(Self.reply(), maxUTF16: 0) == nil)
    }
}

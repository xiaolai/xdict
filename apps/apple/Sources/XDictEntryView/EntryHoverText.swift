import AppKit
import WebKit

/// **The word under a hover point of the entry, as the entry's own script answers it** (`hover-word.js`, in the shell's
/// world): the text of the word's block, windowed around the word, the word's start in it (UTF-16) and which ends are
/// cuts. Hover over XDict's own entry asks this instead of Accessibility, whose hit test over this web view waits on
/// WebKit while WebKit waits on the main thread (verifier, 2026-10-19: 1,530 ms on the build Mac, then -25204; this
/// script answered in 1–10 ms).
public struct EntryHoverText: Sendable, Equatable {
    public let text: String
    public let offset: Int
    public let cutStart: Bool
    public let cutEnd: Bool

    /// **A reply is data from a page**, whatever world ran the script: taken only as exactly the four keys the script
    /// writes, `text` 1…`maxUTF16` UTF-16 units, `offset` a whole number on one of them, the cut ends booleans.
    static func validated(_ reply: Any?, maxUTF16: Int) -> EntryHoverText? {
        guard maxUTF16 > 0, let reply = reply as? [String: Any],
              Set(reply.keys) == ["text", "offset", "cutStart", "cutEnd"],
              let raw = reply["text"] as? NSString, paired(raw), let text = reply["text"] as? String,
              (1...maxUTF16).contains(text.utf16.count),
              let offset = whole(reply["offset"]), (0..<text.utf16.count).contains(offset),
              let cutStart = flag(reply["cutStart"]), let cutEnd = flag(reply["cutEnd"])
        else { return nil }
        return EntryHoverText(text: text, offset: offset, cutStart: cutStart, cutEnd: cutEnd)
    }

    /// No surrogate alone: a window cut inside a pair is not text (it fails to become UTF-8, measured 2026-10-19).
    /// Read from the reply's own string: a Swift `String` would already show a lone surrogate as U+FFFD.
    static func paired(_ text: NSString) -> Bool {
        var awaitingTrail = false
        for index in 0..<text.length {
            let unit = text.character(at: index)
            if UTF16.isLeadSurrogate(unit) {
                if awaitingTrail { return false }
                awaitingTrail = true
            } else if UTF16.isTrailSurrogate(unit) {
                if !awaitingTrail { return false }
                awaitingTrail = false
            } else if awaitingTrail {
                return false
            }
        }
        return !awaitingTrail
    }

    /// A number that is not a boolean and has no fraction.
    private static func whole(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < Double(Int32.max) else { return nil }
        return Int(double)
    }

    /// A boolean, and nothing else that bridges to one.
    private static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

extension EntryWebView {
    /// An entry web view with the hover script and the word core it uses installed as every entry installs the shell's
    /// scripts (`EntryPane.install`: the shell's world, document start, main frame only), and no entry: for the
    /// development lab's hover-script run (`XDictEntryLab --hover-script`), which loads synthetic pages in it and asks
    /// them through `hoverText`. The shell's other scripts are left out so the run measures this one.
    public static func withHoverScript(frame: CGRect) -> EntryWebView {
        let configuration = WKWebViewConfiguration()
        EntryPane.install([EntryScripts.wordClicksCore, EntryScripts.hoverWord], into: configuration.userContentController)
        return EntryWebView(frame: frame, configuration: configuration)
    }

    /// An entry web view with every script an entry installs (light, the whole reading frame, no display options), and
    /// no entry: for the same lab run's pages that measure what the shell's scripts cost a hostile page to load.
    public static func withEntryScripts(frame: CGRect) -> EntryWebView {
        let configuration = WKWebViewConfiguration()
        EntryPane.install(EntryScripts.installed(.light, frame: .all), into: configuration.userContentController)
        return EntryWebView(frame: frame, configuration: configuration)
    }

    /// **The word at `viewPoint`** — in this view's points, y down from its top — asked of the entry's own script in the
    /// shell's world (`EntryPane.world`), so no page script can answer for it; at most `maxUTF16` units of text. The view's
    /// zoom is taken out, as the page measures in CSS pixels. Nil off a word, with no document, or for any reply out of
    /// shape. It reads, never writes: no event, no request, nothing logged.
    public func hoverText(at viewPoint: CGPoint, maxUTF16: Int) async -> EntryHoverText? {
        let scale = pageZoom * magnification
        guard scale > 0, maxUTF16 > 0 else { return nil }
        let reply = try? await callAsyncJavaScript(
            EntryScripts.askHoverWord, arguments: ["x": viewPoint.x / scale, "y": viewPoint.y / scale, "m": maxUTF16],
            in: nil, contentWorld: EntryPane.world)
        return EntryHoverText.validated(reply, maxUTF16: maxUTF16)
    }
}

/// **The entry's selection, as the entry's own script answers it** (`hover-word.js`'s `__xdictSelectionText`, in the
/// shell's world; owner, 2026-10-20: the shortcut, the menu and the Service capture the sentence in XDict's own windows
/// too): the shown selected text and, where asked for, the shown text of its block around it — or that the selection is
/// longer than it was asked to read. Asked instead of Accessibility, whose requests about this web view wait on WebKit
/// while WebKit waits on the main thread (ADR-0014 d.6).
public enum EntrySelectionText: Sendable, Equatable {
    /// The selection as shown, and the text around it with the selection at its offset, or nil where none was asked
    /// for or the selection crosses blocks.
    case selected(String, around: EntryHoverText?)
    /// More than the bound asked for, or more than the script's own walk reaches: said, never cut.
    case tooLong

    /// **A reply is data from a page**, whatever world ran the script: taken only as exactly `{over: true}`, or exactly
    /// `selected` (1…`maxUTF16` UTF-16 units, no lone surrogate) and `around` (null, or a hover reply's shape within the
    /// bound, holding `selected` exactly at its offset).
    static func validated(_ reply: Any?, maxUTF16: Int) -> EntrySelectionText? {
        guard maxUTF16 > 0, let reply = reply as? [String: Any] else { return nil }
        if Set(reply.keys) == ["over"] {
            guard let over = reply["over"] as? NSNumber, CFGetTypeID(over) == CFBooleanGetTypeID(), over.boolValue
            else { return nil }
            return .tooLong
        }
        guard Set(reply.keys) == ["selected", "around"], let raw = reply["selected"] as? NSString,
              EntryHoverText.paired(raw), (1...maxUTF16).contains(raw.length), let selected = reply["selected"] as? String
        else { return nil }
        if reply["around"] is NSNull { return .selected(selected, around: nil) }
        guard let around = EntryHoverText.validated(reply["around"], maxUTF16: maxUTF16) else { return nil }
        let text = around.text as NSString
        guard around.offset <= text.length - raw.length,
              text.substring(with: NSRange(location: around.offset, length: raw.length)) == selected
        else { return nil }
        return .selected(selected, around: around)
    }
}

extension EntryWebView {
    /// **The entry's selection**, asked of the entry's own script in the shell's world (`EntryPane.world`), so no page
    /// script can answer for it; with the text around it only where `sentence`; at most `maxUTF16` units of either. Nil
    /// where nothing shown is selected, with no document, or for any reply out of shape. It reads, never writes: no
    /// event, no request, nothing logged, the selection left as it is.
    public func selectionText(sentence: Bool, maxUTF16: Int) async -> EntrySelectionText? {
        guard maxUTF16 > 0 else { return nil }
        let reply = try? await callAsyncJavaScript(
            EntryScripts.askSelectionText, arguments: ["s": sentence, "m": maxUTF16], in: nil, contentWorld: EntryPane.world)
        return EntrySelectionText.validated(reply, maxUTF16: maxUTF16)
    }
}

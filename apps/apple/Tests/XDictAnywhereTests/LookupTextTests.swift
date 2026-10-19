import Testing
import XDictAnywhere
import XDictCaptureMac

/// **What is looked up, from whatever the reader selected** — by the shortcut (the Accessibility API) or by the
/// Service (the pasteboard macOS hands it). One rule for both: the selection less its wrapping punctuation, Unicode and
/// phrases kept exactly. Moved from XiaolaiDict (`SelectedTermTests`); the term's own cases moved on with `SelectedTerm`
/// to `XDictCaptureMacTests` (plan-capture WI-2), and this keeps the rule lookup adds: what it admits.
struct LookupTextTests {
    // MARK: - The Service's text

    /// **The Service's answer is the selection, as the shortcut's is**: a Unicode phrase delivered intact, its
    /// wrapping punctuation off; nothing, only punctuation and too much each refused by kind.
    @Test func theServicesTextIsTheSameRule() {
        #expect(LookupText.term(" crème brûlée 煎饼 ") == .term("crème brûlée 煎饼"))
        #expect(LookupText.term("“take off,”") == .term("take off"))
        #expect(LookupText.term(nil) == .empty)
        #expect(LookupText.term("  \n") == .empty)
        #expect(LookupText.term("“…”") == .noWord)
        let long = String(repeating: "a", count: LookupText.maximumLength + 1)
        #expect(LookupText.term(long) == .tooLong(characters: LookupText.maximumLength + 1))
        #expect(LookupText.term(String(repeating: "a", count: LookupText.maximumLength)) != .tooLong(
            characters: LookupText.maximumLength))
    }

    /// **The shortcut is handed the Service's limit**: the reader moved down to capture (plan-capture WI-2) and the limit
    /// stayed here, the consumer's (XDict ADR-0014 decision 3) — one number for both routes, or a selection the Service
    /// refuses as too long would be looked up from the shortcut.
    @Test func theShortcutIsHandedTheServicesLimit() {
        #expect(LookupText.admission == TermAdmission(maximumCharacters: LookupText.maximumLength))
        let longest = String(repeating: "a", count: LookupText.maximumLength)
        #expect(LookupText.admission.admits(longest) && !LookupText.admission.admits(longest + "a"))
    }
}

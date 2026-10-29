import AppKit
import Testing
@testable import XDictTokens

/// **A serif role falls back to a Chinese serif, not to a sans** (owner, 2026-10-29; `note-cjk-typography-2026-10-29.md`):
/// SwiftUI's serif design has no Han glyphs, and the system's own fallback for them is PingFang — a sans — so the start
/// page's prompt and the answer pane drew a serif Latin and a sans Chinese on one line. Songti SC, the system's Chinese
/// serif, sits behind every serif role; the other roles are untouched.
struct SerifCascadeTests {
    @Test func aSerifRoleCarriesTheChineseSerifBehindIt() {
        let cascade = Tokens.TextRole.startName.nsFont.fontDescriptor.object(forKey: .cascadeList)
            as? [NSFontDescriptor] ?? []
        let names = cascade.compactMap { $0.object(forKey: .name) as? String }
        #expect(names.contains(TokenFont.chineseSerif), "the serif role has no Chinese serif behind it: \(names)")
    }

    @Test func theOtherRolesAreLeftAsTheyWere() {
        let cascade = Tokens.TextRole.panelTitle.nsFont.fontDescriptor.object(forKey: .cascadeList)
            as? [NSFontDescriptor] ?? []
        #expect(cascade.isEmpty, "a sans role must keep the system's own fallback")
    }
}

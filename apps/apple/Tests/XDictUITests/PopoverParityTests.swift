import AppKit
import Testing
import XDictAnywhere
@testable import XDictUI

/// **The lookup panel imitates the system Look Up popover** (P41; owner, 2026-10-17). The numbers are the popover's own,
/// measured on macOS 27.0.1 over a TextEdit document (`dev-docs/artifacts/apple-dictionary/apple/popover.*`): a 390 pt
/// body centred under the word, a 20 pt title row followed by a rule, and footer rows for "Open in …" and "Configure
/// Dictionaries", with no window buttons.
@MainActor
struct PopoverParityTests {
    @Test func thePanelOpensAsWideAsThePopoverBody() {
        #expect(PanelPlacement.widths.default == 390)
    }

    @Test func theTitleRowIsTheSystemFontAtTwentyPointsInsetTwentyFour() {
        #expect(PanelLook.titleSize == 20)
        #expect(PanelLook.leading == 24 && PanelLook.trailing == 27)
        #expect(PanelLook.topSpace == 16 && PanelLook.titleRow == 24)
    }

    @Test func theFooterRowsAreTwentySixPointsUnderAnEightPointGap() {
        #expect(PanelLook.footerRow == 26 && PanelLook.footerGap == 8)
        #expect(PanelLook.footerLeading == 26 && PanelLook.footerFontSize == 13)
        // Title row, the gap under it, then two footer rows, each with its gap and its hairline, and the bottom inset.
        let footerRows: CGFloat = 2 * (8 + 26 + 1) + 8
        #expect(LookupPanelView.chromeHeight == 16 + 24 + 8 + footerRows)
    }
}

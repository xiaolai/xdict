import AppKit
import Testing
@testable import XDictEntryView

/// **In the lookup popover the entry is drawn on the popover's glass** (P41; orchestrator's eye check, 2026-10-18): the
/// page and the web view under it are clear there, as Apple's entry text sits on the glass; in the main window, and in
/// "Original style" (whose dictionary colours assume a page), they stay opaque.
@MainActor
struct PanelPageTests {
    private static let panel = EntryReadingFrame.all.union(.panel)

    @Test func thePanelDensityClearsThePage() {
        let installed = EntryScripts.installed(.light, frame: Self.panel).joined(separator: "\n")
        #expect(installed.contains(":root[data-xdict-density=panel]{background-color:transparent !important}"))
    }

    @Test func theWebViewIsClearInThePopoverAndOpaqueElsewhere() {
        for scheme in [EntryColourScheme.light, .dark] {
            #expect(EntryPane.page(scheme, frame: Self.panel) == .init(draws: false, under: .clear))
            #expect(EntryPane.page(scheme, frame: .all).draws)
            #expect(EntryPane.page(scheme, frame: .all).under.alphaComponent == 1)
            #expect(EntryPane.page(scheme, frame: .minimal).draws, "Original style keeps its page")
        }
    }
}

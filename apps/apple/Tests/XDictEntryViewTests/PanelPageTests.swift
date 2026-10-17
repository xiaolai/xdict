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

    /// WCAG's contrast of two `#rrggbb` colours.
    private static func contrast(_ a: String, _ b: String) -> Double {
        func luminance(_ hex: String) -> Double {
            let v = Int(hex.dropFirst(), radix: 16) ?? 0
            func channel(_ c: Int) -> Double {
                let x = Double(c) / 255
                return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(v >> 16 & 255) + 0.7152 * channel(v >> 8 & 255) + 0.0722 * channel(v & 255)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// **The popover keeps each dictionary's colours where they hold 4.5:1 on its glass, and flattens only the ones
    /// that do not** (owner, 2026-10-18). The glass is measured from captures (`PopoverGlass`): light over a busy
    /// wallpaper and over a white document, dark over the dark desktop; a colour is kept when it holds 4.5:1 on every
    /// sample of its theme. Light's busy glass is mid-grey, so there little but the primary colour holds; dark keeps
    /// its pale tiers.
    @Test func thePopoverKeepsEveryColourThatHoldsOnTheGlassAndFlattensTheRest() {
        #expect(PopoverGlass.samples.light.count >= 2 && PopoverGlass.samples.dark.count >= 1)
        let css = EntryReadingFrame.popoverColoursCSS
        for scheme in [EntryColourScheme.light, .dark] {
            let samples = scheme == .light ? PopoverGlass.samples.light : PopoverGlass.samples.dark
            let selector = ":root[data-xdict-density=panel][data-xdict-theme=\(scheme.rawValue)]"
            // The accent is set per hue (below), so it is checked there.
            for (name, light, dark) in EntryReadingFrame.colours where PopoverGlass.isText(name) && name != "accent" {
                let value = scheme == .light ? light : dark
                let holds = samples.allSatisfy { Self.contrast(value, $0) >= PopoverGlass.minimum }
                let flattened = Self.block(css, selector).contains("--xdict-\(name):var(--xdict-text) !important")
                #expect(flattened == !holds, "\(scheme.rawValue) \(name) \(value)")
            }
            for accent in EntryReadingFrame.Accent.allCases {
                let value = scheme == .light ? accent.values.light : accent.values.dark
                let holds = samples.allSatisfy { Self.contrast(value, $0) >= PopoverGlass.minimum }
                let hue = "\(selector)[data-xdict-hue=\(accent.rawValue)]"
                #expect(Self.block(css, hue).contains("--xdict-accent:var(--xdict-text) !important") == !holds,
                        "\(scheme.rawValue) accent \(accent.rawValue)")
            }
        }
        // The primary colour itself holds everywhere: it is what the others become.
        #expect(PopoverGlass.samples.light.allSatisfy { Self.contrast("#000000", $0) >= PopoverGlass.minimum })
        #expect(PopoverGlass.samples.dark.allSatisfy { Self.contrast("#ffffff", $0) >= PopoverGlass.minimum })
        // Dark keeps some colours (its deep tier is pale), light flattens its greys and links.
        #expect(!Self.block(css, ":root[data-xdict-density=panel][data-xdict-theme=dark]").contains("--xdict-red-deep:"))
        #expect(Self.block(css, ":root[data-xdict-density=panel][data-xdict-theme=light]").contains("--xdict-text-2:"))
        // No blanket rule flattens them all whatever the theme (the rule of 2026-10-18 before the owner's decision).
        #expect(!EntryScripts.installed(.dark, frame: Self.panel).joined().contains(":root[data-xdict-density=panel]{--xdict-text-2:"))
        // Installed in the popover only, never in the main window.
        #expect(EntryScripts.installed(.light, frame: Self.panel).joined()
            .contains(":root[data-xdict-density=panel][data-xdict-theme=light]{--xdict-text-2:var(--xdict-text) !important;"))
        #expect(!EntryScripts.installed(.light, frame: .all).joined().contains("data-xdict-density=panel][data-xdict-theme"))
    }

    /// The declarations of the rule `selector` opens (exactly that selector, not a longer one).
    private static func block(_ css: String, _ selector: String) -> String {
        guard let start = css.range(of: selector + "{") else { return "" }
        return String(css[start.upperBound...].prefix { $0 != "}" })
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

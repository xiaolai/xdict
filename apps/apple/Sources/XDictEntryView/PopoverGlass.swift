import Foundation

/// **The lookup popover's glass, as measured** (P41; owner, 2026-10-18: "keep each dictionary's own colours where they
/// pass 4.5:1 on the popover's glass, flatten only the colours that fail"). The popover material blends what is behind
/// the window, so its colour is a range, not a value: these are the worst samples of it, read from captures of the
/// popover on the E2E Mac (`dev-docs/artifacts/apple-dictionary/xdict/`): in light the darkest glass over the busy
/// wallpaper (`popover.textedit.png`, #939bb1) and the darkest over a white document (#dcdee3); in dark the lightest
/// glass over the dark desktop (`popover-material.dark-desktop.png`, #343e4f) and its darkest (#202336). Dark text is
/// read against light's samples, light text against dark's.
public enum PopoverGlass {
    /// WCAG AA for body text.
    public static let minimum: Double = 4.5

    public static let samples: (light: [String], dark: [String]) = (["#939bb1", "#dcdee3"], ["#343e4f", "#202336"])

    /// Whether a palette token is a text colour (the others are surfaces, rules and tints, never text).
    public static func isText(_ token: String) -> Bool {
        !["bg", "panel", "rule", "plate"].contains(token) && !token.hasSuffix("-tint") && token != "text"
    }

    /// Whether `hex` holds `minimum` against every sample of its theme.
    public static func holds(_ hex: String, scheme: EntryColourScheme) -> Bool {
        (scheme == .light ? samples.light : samples.dark).allSatisfy { contrast(hex, $0) >= minimum }
    }

    /// WCAG's contrast ratio of two `#rrggbb` colours.
    public static func contrast(_ a: String, _ b: String) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func luminance(_ hex: String) -> Double {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        func channel(_ c: Int) -> Double {
            let x = Double(c) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(v >> 16 & 255) + 0.7152 * channel(v >> 8 & 255) + 0.0722 * channel(v & 255)
    }
}

extension EntryReadingFrame {
    /// **The popover's colours**: per theme, every text token of the palette that fails 4.5:1 on the glass
    /// (`PopoverGlass`) drawn as the primary colour, and every one that holds left as the dictionary has it; the
    /// accent likewise per hue. Only on the popover's page (`data-xdict-density=panel`).
    static var popoverColoursCSS: String {
        var css = ""
        for scheme in [EntryColourScheme.light, .dark] {
            let selector = ":root[data-xdict-density=panel][data-xdict-theme=\(scheme.rawValue)]"
            let failing = colours.filter { PopoverGlass.isText($0.0) && $0.0 != "accent" }
                .filter { !PopoverGlass.holds(scheme == .light ? $0.1 : $0.2, scheme: scheme) }
                .map { "--xdict-\($0.0):var(--xdict-text) !important;" }
            if !failing.isEmpty { css += "\(selector){\(failing.joined())}" }
            for accent in Accent.allCases
            where !PopoverGlass.holds(scheme == .light ? accent.values.light : accent.values.dark, scheme: scheme) {
                css += "\(selector)[data-xdict-hue=\(accent.rawValue)]{--xdict-accent:var(--xdict-text) !important;}"
            }
        }
        return css
    }
}

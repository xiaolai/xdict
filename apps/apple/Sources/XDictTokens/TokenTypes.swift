import AppKit
import SwiftUI

/// **A text role** (`Tokens.TextRole`): a system text style, which follows the reader's settings, or a size Apple
/// measured, with its weight, design and slant. One value, two faces: `font` for SwiftUI, `nsFont` for AppKit.
public struct TokenFont: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2
    }

    public enum Weight: Sendable, Equatable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    }

    public enum Design: Sendable, Equatable {
        case `default`, serif, rounded, monospaced
    }

    enum Spec: Sendable, Equatable {
        case style(Style, Weight?)
        case fixed(size: CGFloat, weight: Weight, design: Design, italic: Bool)
    }

    let spec: Spec

    public init(style: Style, weight: Weight? = nil) { spec = .style(style, weight) }

    public init(size: CGFloat, weight: Weight, design: Design, italic: Bool) {
        spec = .fixed(size: size, weight: weight, design: design, italic: italic)
    }

    /// The size Apple measured, or nil for a system text style (whose size is the reader's).
    public var pointSize: CGFloat? {
        if case .fixed(let size, _, _, _) = spec { size } else { nil }
    }

    /// For SwiftUI.
    public var font: Font {
        switch spec {
        case .style(let style, let weight):
            let font = Font.system(style.swiftUI)
            return weight.map { font.weight($0.swiftUI) } ?? font
        case .fixed(let size, let weight, let design, let italic):
            let font = Font.system(size: size, weight: weight.swiftUI, design: design.swiftUI)
            return italic ? font.italic() : font
        }
    }

    /// For AppKit.
    public var nsFont: NSFont {
        switch spec {
        case .style(let style, let weight):
            let font = NSFont.preferredFont(forTextStyle: style.appKit)
            guard let weight else { return font }
            return NSFont.systemFont(ofSize: font.pointSize, weight: weight.appKit)
        case .fixed(let size, let weight, let design, let italic):
            var descriptor = NSFont.systemFont(ofSize: size, weight: weight.appKit).fontDescriptor
            if let designed = descriptor.withDesign(design.appKit) { descriptor = designed }
            if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic)) }
            return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight.appKit)
        }
    }
}

extension TokenFont.Style {
    var swiftUI: Font.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption
        case .caption2: .caption2
        }
    }

    var appKit: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        }
    }
}

extension TokenFont.Weight {
    var swiftUI: Font.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }

    var appKit: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
}

extension TokenFont.Design {
    var swiftUI: Font.Design {
        switch self {
        case .default: .default
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
    }

    var appKit: NSFontDescriptor.SystemDesign {
        switch self {
        case .default: .default
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
    }
}

/// **A colour** (`Tokens.Colour`): one of the system's semantic colours, or a light and a dark sRGB value measured on
/// Apple's page, chosen by the drawing appearance. `nsColor` for AppKit, `color` for SwiftUI.
public struct TokenColour {
    public let nsColor: NSColor

    public init(_ system: NSColor) { nsColor = system }

    /// `0xRRGGBB` in light and in dark.
    public init(light: UInt32, dark: UInt32) {
        nsColor = NSColor(name: nil) { appearance in
            Self.srgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    public var color: Color { Color(nsColor: nsColor) }

    static func srgb(_ rgb: UInt32) -> NSColor {
        func channel(_ shift: UInt32) -> CGFloat { CGFloat((rgb >> shift) & 0xFF) / 255 }
        return NSColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }
}

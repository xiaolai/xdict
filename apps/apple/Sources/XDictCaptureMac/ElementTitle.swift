import ApplicationServices
import CoreText
import Foundation
import XDictCapture

/// **The text a control draws as its label, and the word of it under the pointer** — for elements that expose their text
/// only as a string, with no range or box to ask (measured 2026-10-19 on macOS 27.0.1: a menu bar item answers `AXTitle`
/// and no parameterized attribute; a SwiftUI pop-up button its `AXValue`; a push button, a tab, a check box their
/// `AXTitle`). The three text dialects find nothing in them, so before this every menu, button and tab was a miss.
///
/// **Where the word is, estimated and never invented.** The title's line is laid out with the font the system draws that
/// kind of control in (CoreText's UI fonts, at their system size: no size is written here), placed in the element's frame
/// by how that control aligns its label. Where the placement is not known exactly — a label at the leading edge after an
/// inset nobody reports (a check box's box, a menu item's state column) — **every placement the frame allows is tried,
/// and the word is taken only where all of them agree** and the pointer is on the text in all of them. Text wider than
/// its frame is not drawn as one line there (truncated, wrapped, or not this font), and answers nothing. The pixels are
/// the next path for every case this declines.
///
/// **Never `AXDescription`**: it is the label an icon is spoken by, not text on screen; read, it would look up "Back" from
/// a chevron. **Never a secure field's anything**: `PointerWordReader` refuses one before any text attribute is asked.
enum ElementTitle {
    /// How a control places its label in its frame.
    enum Alignment: Sendable, Equatable {
        /// Centred: a menu bar item, a push button, a tab or segment.
        case centred
        /// At the leading edge (the right, for right-to-left text), after an inset that is not reported.
        case leading
    }

    /// The system font a control draws its label in.
    enum Style: Sendable, Equatable {
        case menuBar, menu, control

        var font: CTFont? {
            let kind: CTFontUIFontType = switch self {
            case .menuBar: .menuTitle
            case .menu: .menuItem
            case .control: .system
            }
            // Size 0: the system's own size for that kind.
            return CTFontCreateUIFontForLanguage(kind, 0, nil)
        }
    }

    /// Where a role keeps its label, how it aligns it, and in which font.
    struct Source: Sendable, Equatable {
        let attribute: String
        let alignment: Alignment
        let style: Style
    }

    /// **The roles whose label is their drawn text**, and nothing else. A role not listed has no title read.
    static func source(role: String?, subrole: String?) -> Source? {
        switch role {
        case "AXMenuBarItem": Source(attribute: kAXTitleAttribute, alignment: .centred, style: .menuBar)
        case "AXMenuItem": Source(attribute: kAXTitleAttribute, alignment: .leading, style: .menu)
        case "AXButton", "AXMenuButton":
            // The window's own buttons draw no text.
            [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole, kAXFullScreenButtonSubrole]
                .contains(subrole ?? "") ? nil : Source(attribute: kAXTitleAttribute, alignment: .centred, style: .control)
        case "AXRadioButton": Source(attribute: kAXTitleAttribute, alignment: .centred, style: .control)
        case "AXCheckBox", "AXDisclosureTriangle": Source(attribute: kAXTitleAttribute, alignment: .leading, style: .control)
        case "AXPopUpButton": Source(attribute: kAXValueAttribute, alignment: .leading, style: .control)
        case "AXStaticText": Source(attribute: kAXValueAttribute, alignment: .leading, style: .control)
        default: nil
        }
    }

    /// The word of `text` under `point`, its sentence the label itself, or nil where the label cannot be placed under the
    /// pointer with certainty. `limits` bounds the label before anything is laid out or segmented.
    static func word(
        in text: String, frame: CGRect, alignment: Alignment, style: Style, at point: CGPoint, tolerance: HitTolerance,
        limits: CaptureLimits
    ) -> WordAtPoint? {
        guard !text.isEmpty, text.utf16.count <= limits.contextUTF16, !text.contains(where: \.isNewline),
              frame.width > 0, frame.height > 0, frame.minX.isFinite, frame.minY.isFinite,
              tolerance.distance(from: point, to: frame) != nil,
              let font = style.font, let layout = Layout(text, font: font)
        else { return nil }
        let ranges = TextSegmenter.wordRanges(in: text)
        guard !ranges.isEmpty, ranges.count <= PointerWordReader.maximumScannedWords,
              layout.width <= frame.width + tolerance.horizontal
        else { return nil }
        let slack = max(0, frame.width - layout.width)
        let rightToLeft = layout.isRightToLeft
        // Every origin the frame allows the line, from the one alignment says to the furthest the inset could put it.
        let origins: [CGFloat] = switch alignment {
        case .centred: [frame.minX + slack / 2]
        case .leading: rightToLeft ? [frame.maxX - layout.width, frame.minX] : [frame.minX, frame.minX + slack]
        }
        var agreed: Range<String.Index>?
        for origin in origins {
            guard let range = layout.word(among: ranges, in: text, at: point.x - origin, tolerance: tolerance.horizontal),
                  agreed.map({ $0 == range }) ?? true
            else { return nil }
            agreed = range
        }
        guard let agreed else { return nil }
        return TextSegmenter.word(in: text, utf16Offset: text.utf16.distance(from: text.startIndex, to: agreed.lowerBound))
    }

    /// The label's single line as CoreText lays it out: its width, its direction and each character's caret offset.
    struct Layout {
        let line: CTLine
        let width: CGFloat
        let isRightToLeft: Bool

        init?(_ text: String, font: CTFont) {
            let attributed = NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            line = CTLineCreateWithAttributedString(attributed)
            width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard width.isFinite, width > 0 else { return nil }
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            isRightToLeft = runs.first.map { CTRunGetStatus($0).contains(.rightToLeft) } ?? false
        }

        /// The x span of `range` on the line, from its carets: both ends, either order, so a right-to-left run reads too.
        func span(of range: Range<String.Index>, in text: String) -> ClosedRange<CGFloat> {
            let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.utf16.distance(from: text.startIndex, to: range.upperBound)
            let a = CTLineGetOffsetForStringIndex(line, start, nil)
            let b = CTLineGetOffsetForStringIndex(line, end, nil)
            return min(a, b)...max(a, b)
        }

        /// The word whose span holds `x` (line coordinates), the nearer within `tolerance`, or nil off every word.
        func word(
            among ranges: [Range<String.Index>], in text: String, at x: CGFloat, tolerance: CGFloat
        ) -> Range<String.Index>? {
            var best: (range: Range<String.Index>, distance: CGFloat)?
            for range in ranges {
                let span = span(of: range, in: text)
                let distance = max(span.lowerBound - x, 0, x - span.upperBound)
                guard distance <= tolerance else { continue }
                if best.map({ distance < $0.distance }) ?? true { best = (range, distance) }
            }
            return best?.range
        }
    }
}

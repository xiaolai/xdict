import ApplicationServices
import Foundation
import XDictCapture

/// **The text a control draws as its label, and the word of it under the pointer** — for elements that expose their text
/// only as a string, with no range or box to ask (measured 2026-10-19 on macOS 27.0.1: a menu bar item answers `AXTitle`
/// and no parameterized attribute; a SwiftUI pop-up button its `AXValue`; a push button, a tab, a check box their
/// `AXTitle`). The three text dialects find nothing in them, so before this every menu, button and tab was a miss.
///
/// **Where the word is, estimated and never invented.** The label's line is laid out with the font the system draws that
/// kind of control in (CoreText's UI fonts, at their system size: no size is written here). Where it sits is not known —
/// leading, centred or trailing, pushed aside by an icon, a radio circle or a chevron (`LabelSlack.shift`), in a font
/// down to `LabelSlack.smaller` smaller or as large as the frame allows — so **every such placement and size is tried,
/// and a word is taken only where all of them put the pointer inside that same word**; anywhere else, nothing. The slack
/// is **a chosen safety margin, not a measurement**: no real control's offset was measured (2026-10-19). Under the
/// oracle's assumed model of labels up to 12 pt off centre, one centred placement answered a word the pointer was not on
/// for 14.5% of its answers (verifier, 2026-10-19); a label pushed further than the margin is outside what this guards.
/// The pointer must also be within the line's height. A frame not wider than its label plus the tolerance answers nothing:
/// the label may be truncated, wrapped, or not text at all (the Apple menu's "Apple" is a logo, 35 pt of text in a 34 pt
/// frame, and is refused by name too). **Vertically the line is assumed centred**: a control taller than two of its lines
/// (an icon above its label, as a toolbar item draws) answers nothing, since its label may sit anywhere in that height;
/// the menu bar's items are exempt, one centred line in a bar 33 to 38 pt tall. Requiring agreement of top, centre and
/// bottom placements instead would refuse every menu bar title, its bar being more than two lines tall on a notched
/// screen. `TitleOracleTests` holds this against labels laid out at their true places in that model: no answer is a word
/// the pointer is not on. The pixels are the next path for every case this declines.
///
/// **Never `AXDescription`**: it is the label an icon is spoken by, not text on screen; read, it would look up "Back" from
/// a chevron. **Never a secure field's anything**: `PointerWordReader` refuses one before any text attribute is asked.
enum ElementTitle {
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

    /// Where a role keeps its label, and in which font. Where in the frame is never assumed: every placement is tried.
    struct Source: Sendable, Equatable {
        let attribute: String
        let style: Style
    }

    /// **The roles whose label is their drawn text**, and nothing else. A role not listed has no title read.
    static func source(role: String?, subrole: String?) -> Source? {
        switch role {
        case "AXMenuBarItem": Source(attribute: kAXTitleAttribute, style: .menuBar)
        case "AXMenuItem": Source(attribute: kAXTitleAttribute, style: .menu)
        case "AXButton", "AXMenuButton":
            // The window's own buttons draw no text.
            [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole, kAXFullScreenButtonSubrole]
                .contains(subrole ?? "") ? nil : Source(attribute: kAXTitleAttribute, style: .control)
        case "AXRadioButton", "AXCheckBox", "AXDisclosureTriangle": Source(attribute: kAXTitleAttribute, style: .control)
        case "AXPopUpButton", "AXStaticText": Source(attribute: kAXValueAttribute, style: .control)
        default: nil
        }
    }

    /// The smallest font tried, as a share of the system's size for the kind: `slack.smaller` below it.
    static func smallestScale(of font: CTFont, slack: LabelSlack) -> CGFloat {
        let size = CTFontGetSize(font)
        return size > slack.smaller ? (size - slack.smaller) / size : 1
    }

    /// The word of `text` under `point`, its sentence the label itself, or nil where not every placement and size the
    /// frame and `slack` allow put the pointer inside one same word. `limits` bounds the label before anything is laid
    /// out or segmented.
    static func word(
        in text: String, frame: CGRect, style: Style, at point: CGPoint, tolerance: HitTolerance, slack: LabelSlack,
        limits: CaptureLimits
    ) -> WordAtPoint? {
        guard !text.isEmpty, text.utf16.count <= limits.contextUTF16, !text.contains(where: \.isNewline),
              !(style == .menuBar && text == "Apple"),
              frame.width > 0, frame.height > 0, frame.minX.isFinite, frame.minY.isFinite,
              tolerance.distance(from: point, to: frame) != nil,
              let font = style.font, let layout = Layout(text, font: font)
        else { return nil }
        let ranges = TextSegmenter.wordRanges(in: text)
        guard !ranges.isEmpty, ranges.count <= PointerWordReader.maximumScannedWords,
              frame.width > layout.width + tolerance.horizontal,
              // Taller than two lines: the label may sit anywhere in the height, under an icon.
              style == .menuBar || frame.height <= 2 * layout.lineHeight + tolerance.vertical
        else { return nil }
        // **Within the line's height**, at its smallest, centred in the frame.
        let smallest = smallestScale(of: font, slack: slack)
        guard abs(point.y - frame.midY) <= layout.lineHeight * smallest / 2 + tolerance.vertical else { return nil }
        let spans = ranges.map { layout.span(of: $0, in: text) }
        // **Every scale from the smallest font to the one that fills the frame, checked at its two ends only.** The
        // pointer's place on the line is furthest right at the leftmost placement and furthest left at the rightmost, so
        // the word holds for every placement and scale if those two extremes stay in it. Each is (x − a)/s + b on either
        // side of the scale where the off-centre bound meets the frame's edge; there the leftmost placement can only
        // reach a minimum of its place and the rightmost only a maximum — never the extreme that decides — so the
        // largest and smallest places lie at the ends. That middle scale was checked until 2026-10-20; dropping it
        // changed no answer (verifier's mutant T03), and `TitleOracleTests.everySizeBetweenTheEndsAgrees` samples 401
        // scales between the ends against this.
        let largest = frame.width / layout.width
        var agreed: Int?
        for scale in [smallest, largest] {
            let width = layout.width * scale
            let centred = frame.minX + (frame.width - width) / 2
            let lowest = min(frame.minX, centred - slack.shift)
            let highest = max(frame.maxX - width, centred + slack.shift)
            for origin in [lowest, highest] {
                let along = (point.x - origin) / scale
                guard let index = spans.firstIndex(where: { $0.contains(along) }),
                      agreed.map({ $0 == index }) ?? true
                else { return nil }
                agreed = index
            }
        }
        guard let agreed else { return nil }
        return TextSegmenter.word(
            in: text, utf16Offset: text.utf16.distance(from: text.startIndex, to: ranges[agreed].lowerBound))
    }

    /// The label's single line as CoreText lays it out: its width, its height and each character's caret offset.
    struct Layout {
        let line: CTLine
        let width: CGFloat
        /// The line's ascent and descent: how tall the text itself is.
        let lineHeight: CGFloat

        init?(_ text: String, font: CTFont) {
            let attributed = NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            line = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            lineHeight = ascent + descent
            guard width.isFinite, width > 0, lineHeight.isFinite, lineHeight > 0 else { return nil }
        }

        /// The x span of `range` on the line, from its carets: both ends, either order, so a right-to-left run reads too.
        func span(of range: Range<String.Index>, in text: String) -> ClosedRange<CGFloat> {
            let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.utf16.distance(from: text.startIndex, to: range.upperBound)
            let a = CTLineGetOffsetForStringIndex(line, start, nil)
            let b = CTLineGetOffsetForStringIndex(line, end, nil)
            return min(a, b)...max(a, b)
        }
    }
}

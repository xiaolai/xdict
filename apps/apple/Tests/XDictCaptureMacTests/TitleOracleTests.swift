import AppKit
import ApplicationServices
import Foundation
import Testing
import XDictCapture
@testable import XDictCaptureMac

/// **A property test of `ElementTitle.word` against where the label really is** (verifier, 2026-10-19: the first rule
/// returned a word the pointer was not on for 14.5% of answers once a label sat off centre). Synthetic labels are laid
/// out with CoreText at true positions the reader cannot see — leading, centred, trailing, centred and pushed 4–12 pt
/// aside (an icon or a radio circle beside the title), in the nominal font, bold, 2 pt smaller or larger, at a 22 pt title
/// size; right-to-left, Chinese and emoji among them; paddings 0–180 pt — and the reader is asked at every point
/// across the frame and a little beyond, at its top and bottom edges. **Whenever it answers a
/// word, the pointer is within the tolerance of that word's true glyph box: the wrong-answer rate is zero.** Where the
/// placements cannot agree it answers nothing, and the pixels are the next path. The share of positions still answered is
/// printed, so a rule that answers nothing at all cannot pass unseen (`answeredSomewhere`).
struct TitleOracleTests {
    static let texts = ["Open Recent", "Bambu Studio Extras", "Add Dictionary", "Look Up Word", "Show All Dictionaries",
                        "Save As…", "Hello 👋 World", "قاموس عربي كبير", "牛津 高阶 词典", "Read text with",
                        "Oxford Advanced Learner", "File", "Window"]
    static let tolerance = Measured.hit

    enum Placement: CaseIterable { case leading, centred, trailing, offCentre }
    enum Face: String, CaseIterable { case nominal, bold, smaller, larger, title }

    static func font(_ face: Face, _ style: ElementTitle.Style) -> CTFont? {
        guard let base = style.font else { return nil }
        let size = CTFontGetSize(base)
        switch face {
        case .nominal: return base
        case .bold: return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold)
        case .smaller: return CTFontCreateCopyWithAttributes(base, size - 2, nil, nil)
        case .larger: return CTFontCreateCopyWithAttributes(base, size + 2, nil, nil)
        case .title: return CTFontCreateCopyWithAttributes(base, 22, nil, nil)
        }
    }

    struct Tally {
        var asked = 0, answered = 0, wrong = 0
        var examples: [String] = []
    }

    /// Every true layout of every label, swept by the pointer.
    static func sweep(faces: [Face]) -> Tally {
        var tally = Tally()
        let pads: [CGFloat] = [0, 2, 6, 12, 24, 60, 180]
        for text in texts {
            let ranges = TextSegmenter.wordRanges(in: text)
            for style in [ElementTitle.Style.menuBar, .menu, .control] {
                for face in faces {
                    guard let font = font(face, style), let truth = ElementTitle.Layout(text, font: font) else { continue }
                    for pad in pads {
                        let frame = CGRect(x: 100, y: 50, width: (truth.width + pad).rounded(.up),
                                           height: max(22, (truth.lineHeight + 4).rounded(.up)))
                        var origins: [CGFloat] = []
                        for placement in Placement.allCases {
                            switch placement {
                            case .leading: origins.append(frame.minX)
                            case .centred: origins.append(frame.minX + (frame.width - truth.width) / 2)
                            case .trailing: origins.append(frame.maxX - truth.width)
                            case .offCentre:
                                for shift: CGFloat in [-12, -8, -4, 4, 8, 12] {
                                    origins.append(frame.minX + (frame.width - truth.width) / 2 + shift)
                                }
                            }
                        }
                        // The line's true vertical extent, centred in the frame.
                        let top = frame.midY - truth.lineHeight / 2, bottom = frame.midY + truth.lineHeight / 2
                        for origin in origins {
                            for y in [top + 1, bottom - 1] {
                                var x = frame.minX - 4
                                while x <= frame.maxX + 4 {
                                    defer { x += 1 }
                                    tally.asked += 1
                                    guard let got = ElementTitle.word(
                                        in: text, frame: frame, style: style, at: CGPoint(x: x, y: y),
                                        tolerance: tolerance, slack: Measured.label, limits: .shipped)
                                    else { continue }
                                    tally.answered += 1
                                    let truths = ranges.filter { String(text[$0]) == got.word }.map { range in
                                        let span = truth.span(of: range, in: text)
                                        return max(origin + span.lowerBound - x, 0, x - origin - span.upperBound)
                                    }
                                    let distance = truths.min() ?? .infinity
                                    if distance > tolerance.horizontal {
                                        tally.wrong += 1
                                        if tally.examples.count < 6 {
                                            tally.examples.append("'\(got.word)' of '\(text)' \(style) \(face) pad \(pad) origin+\(origin - frame.minX) x+\(x - frame.minX): \(distance) pt off")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return tally
    }

    /// **Zero wrong answers, in every face**, and the share answered printed for the record.
    @Test(arguments: Face.allCases)
    func noAnswerIsAWordThePointerIsNotOn(face: Face) {
        let tally = Self.sweep(faces: [face])
        let share = Double(tally.answered) / Double(max(tally.asked, 1))
        print("TITLE ORACLE \(face.rawValue): asked \(tally.asked), answered \(tally.answered) (\(String(format: "%.2f", share * 100))%), wrong \(tally.wrong)")
        #expect(tally.wrong == 0, "\(tally.wrong) wrong of \(tally.answered): \(tally.examples)")
    }

    /// The control: the rule still answers somewhere — a short word centred in a tight frame, at its middle.
    @Test func answeredSomewhere() throws {
        let font = try #require(ElementTitle.Style.menuBar.font)
        let layout = try #require(ElementTitle.Layout("Window", font: font))
        let frame = CGRect(x: 100, y: 0, width: layout.width + 8, height: 33)
        let got = ElementTitle.word(in: "Window", frame: frame, style: .menuBar, at: CGPoint(x: frame.midX, y: frame.midY),
                                    tolerance: Self.tolerance, slack: Measured.label, limits: .shipped)
        #expect(got?.word == "Window")
    }
}

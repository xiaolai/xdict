import AppKit
import WebKit

/// **Printing the All page as Apple's Dictionary prints it** (parity P44): every expanded dictionary's entry, in the
/// page's order, each under its name; the divider's triangle and rule are the screen's, not the paper's. Each frame is
/// its own isolated document (ADR-0010), so the page is printed as the frames' own drawings, stacked: never one merged
/// document. A page ends only between lines of text.
enum EntryPrintPlan {
    /// The band holding a dictionary's name above its entry, in points.
    static let header: Double = 28

    struct Section: Equatable {
        let name: String
        /// The section's top in the printed view, its name's band first.
        let top: Double
        let height: Double
        /// Where a page may end inside the entry, in the printed view.
        let breaks: [Double]
    }

    /// The sections to print, stacked: `(name, the frame's height, where its lines leave gaps)`, collapsed ones left out.
    static func layout(_ frames: [(String, Double, [Double])], collapsed: [Bool]) -> [Section] {
        var top = 0.0
        var out: [Section] = []
        for (index, frame) in frames.enumerated() where !(collapsed.indices.contains(index) && collapsed[index]) {
            out.append(Section(name: frame.0, top: top, height: frame.1, breaks: frame.2.map { top + header + $0 }))
            top += header + frame.1
        }
        return out
    }

    /// The gaps between lines: the line boxes `(top, bottom)` merged where they overlap, each run's bottom.
    static func breaks(lines: [(Double, Double)]) -> [Double] {
        var out: [Double] = []
        var bottom: Double?
        for line in lines.sorted(by: { $0.0 < $1.0 }) {
            if let current = bottom, line.0 < current {
                bottom = max(current, line.1)
            } else {
                if let current = bottom { out.append(current) }
                bottom = line.1
            }
        }
        if let bottom { out.append(bottom) }
        return out
    }

    /// Where a page ends: the lowest break at or above `proposed` and at or below `limit`'s other side (AppKit's
    /// `adjustPageHeightNew`: the bottom may move up, never past `limit`); none there, `proposed`.
    static func pageBottom(proposed: Double, limit: Double, breaks: [Double]) -> Double {
        breaks.filter { $0 >= limit && $0 <= proposed }.max() ?? proposed
    }

    /// The text's line boxes and images in a frame's document, in CSS pixels from its top: read in the shell's world.
    static let linesScript = """
        const out = []; const range = document.createRange();
        const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode()) && out.length < 40000) {
            if (!/\\S/.test(node.nodeValue)) { continue; }
            range.selectNodeContents(node);
            for (const r of range.getClientRects()) { out.push([r.top + scrollY, r.bottom + scrollY]); }
        }
        for (const img of document.images) {
            const r = img.getBoundingClientRect();
            if (r.height > 0) { out.push([r.top + scrollY, r.bottom + scrollY]); }
        }
        return out;
        """
}

/// The printed All page: each section's name centred over the frame's own drawing (a PDF of it, vectors kept).
@MainActor
final class EntryPagePrintView: NSView {
    private let breaks: [Double]

    init(width: CGFloat, sections: [(EntryPrintPlan.Section, NSImage)]) {
        breaks = sections.flatMap { [$0.0.top] + $0.0.breaks }.sorted()
        let height = sections.last.map { CGFloat($0.0.top + EntryPrintPlan.header + $0.0.height) } ?? 1
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        for (section, image) in sections {
            let name = NSTextField(labelWithString: section.name)
            name.font = .systemFont(ofSize: 12)
            name.textColor = .secondaryLabelColor
            name.alignment = .center
            name.lineBreakMode = .byTruncatingTail
            name.frame = NSRect(x: 0, y: CGFloat(section.top) + 6, width: width, height: 16)
            addSubview(name)
            let picture = NSImageView(frame: NSRect(x: 0, y: CGFloat(section.top + EntryPrintPlan.header), width: width,
                                                    height: CGFloat(section.height)))
            picture.image = image
            picture.imageScaling = .scaleAxesIndependently
            addSubview(picture)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func adjustPageHeightNew(_ newBottom: UnsafeMutablePointer<CGFloat>, top oldTop: CGFloat,
                                      bottom oldBottom: CGFloat, limit bottomLimit: CGFloat) {
        newBottom.pointee = CGFloat(EntryPrintPlan.pageBottom(proposed: Double(oldBottom), limit: Double(bottomLimit),
                                                              breaks: breaks))
    }
}

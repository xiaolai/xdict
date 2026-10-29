import SwiftUI
import XDictSearch
import XDictTokens

/// **The Explore panel's tabs, which wrap instead of clipping** (plan-word-exploration WI-3; revised 2026-10-29 on the
/// owner's report: the last tab was cut off at the panel's edge, and clicking it made the strip grow).
///
/// A segmented control gives every segment the widest label's width, so seven one-word tabs want about 700 pt inside a
/// panel whose content is 608 — and SwiftUI cannot shrink the control below that, so it overflowed its frame and the
/// popover clipped it. Tabs that wrap have no such width: they sit on one row when they fit and take a second row when
/// they do not, at any text size and in any language, and the panel's width is its own token again.
///
/// The chips are the system's own bordered buttons — the selected one prominent — so the accent and the label colour on
/// it are the system's, never a hand-picked pair. Position only comes from tokens: the gap is `Tokens.Space.xs`.
struct ExploreTabs: View {
    let chosen: ExploreModel.Tab
    let choose: (ExploreModel.Tab) -> Void

    var body: some View {
        ChipWrapLayout(gap: Tokens.Space.xs) {
            ForEach(ExploreModel.Tab.allCases) { tab in
                chip(tab)
            }
        }
        .accessibilityIdentifier("explore.tabs")
    }

    @ViewBuilder private func chip(_ tab: ExploreModel.Tab) -> some View {
        if tab == chosen {
            Button { choose(tab) } label: { Text(ExploreSentences.tab(tab)) }  // placement: explore-tab
                .buttonStyle(.borderedProminent)  // placement: explore-tab
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("explore.tab.\(tab.rawValue)")
        } else {
            Button { choose(tab) } label: { Text(ExploreSentences.tab(tab)) }  // placement: explore-tab
                .buttonStyle(.bordered)  // placement: explore-tab
                .accessibilityIdentifier("explore.tab.\(tab.rawValue)")
        }
    }
}

/// **Chips on one line, or as many lines as they need** (owner, 2026-10-29): SwiftUI has no flow layout, so this is one,
/// and its arithmetic is `ChipWrap.lines` — a pure function with a test of its own, since a layout cannot be measured in
/// this test process.
struct ChipWrapLayout: Layout {
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let room = proposal.width ?? .infinity
        let rows = ChipWrap.lines(sizes: sizes, maxWidth: room, gap: gap)
        let width = rows.map { ChipWrap.width(of: $0, sizes: sizes, gap: gap) }.max() ?? 0
        let height = rows.map { ChipWrap.height(of: $0, sizes: sizes) }.reduce(0, +)
            + gap * CGFloat(max(rows.count - 1, 0))
        // A proposal wider than the chips is the panel's to take: the row is left-aligned in it. A proposal that is
        // absent — or infinite, as a maximum-size measurement asks — gets the chips' own width, never infinity.
        let finite = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return CGSize(width: finite ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in ChipWrap.lines(sizes: sizes, maxWidth: bounds.width, gap: gap) {
            let rowHeight = ChipWrap.height(of: row, sizes: sizes)
            var x = bounds.minX
            for index in row {
                let size = sizes[index]
                subviews[index].place(at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + gap
            }
            y += rowHeight + gap
        }
    }
}

/// **Which chips go on which line** (owner, 2026-10-29), with no view in it: a chip joins the line while the line still
/// fits `maxWidth` with the gap before it, and opens the next one when it does not. A chip wider than the room gets a line
/// to itself rather than being cut.
enum ChipWrap {
    static func lines(sizes: [CGSize], maxWidth: CGFloat, gap: CGFloat) -> [Range<Int>] {
        guard !sizes.isEmpty else { return [] }
        var rows: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let wanted = index == start ? size.width : used + gap + size.width
            if index > start, wanted > maxWidth {
                rows.append(start..<index)
                start = index
                used = size.width
            } else {
                used = wanted
            }
        }
        rows.append(start..<sizes.count)
        return rows
    }

    /// A line's width: its chips and the gaps between them.
    static func width(of row: Range<Int>, sizes: [CGSize], gap: CGFloat) -> CGFloat {
        sizes[row].map(\.width).reduce(0, +) + gap * CGFloat(max(row.count - 1, 0))
    }

    /// A line's height: its tallest chip.
    static func height(of row: Range<Int>, sizes: [CGSize]) -> CGFloat {
        sizes[row].map(\.height).max() ?? 0
    }
}

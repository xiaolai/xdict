import AppKit
import Testing
@testable import XDictEntryView

/// **The find bar's count says nothing once the query is gone** (UI review M-14b, 2026-10-17): it kept announcing
/// "1 of 2" to VoiceOver, at 2 pt wide, after the field was emptied.
@MainActor
struct FindBarTests {
    @Test func anEmptiedQueryLeavesNoCountToRead() {
        let bar = EntryFindBar()
        bar.show(EntryFindResult(visible: 2, hidden: 0, current: 1), query: "a")
        #expect(bar.count.accessibilityLabel()?.isEmpty == false)
        bar.show(nil, query: "")
        #expect(bar.count.stringValue.isEmpty)
        #expect(bar.count.accessibilityLabel() == nil)
    }

    /// Previous and Next are one chevron pair, each still named for VoiceOver (M-14).
    @Test func previousAndNextAreAChevronPairWithNames() {
        let bar = EntryFindBar()
        #expect(bar.steps.segmentCount == 2)
        #expect(bar.steps.trackingMode == .momentary)
        #expect(bar.steps.image(forSegment: 0) != nil && bar.steps.image(forSegment: 1) != nil)
        #expect(bar.steps.accessibilityLabel(forSegment: 0)?.isEmpty == false)
    }
}

extension NSSegmentedControl {
    fileprivate func accessibilityLabel(forSegment segment: Int) -> String? {
        toolTip(forSegment: segment)
    }
}

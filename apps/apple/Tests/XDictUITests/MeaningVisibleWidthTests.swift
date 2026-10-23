import AppKit
import Testing
import XDictTokens
@testable import XDictUI

/// A native view's layout must not mutate the SwiftUI state that sizes it again in the same layout pass.
@MainActor
struct MeaningVisibleWidthTests {
    @Test func measuringWaitsUntilTheLayoutPassHasEnded() async {
        let probe = VisibleWidth.Probe()
        var installing = true
        var changedDuringLayout = false
        var widths: [CGFloat] = []
        probe.changed = {
            changedDuringLayout = changedDuringLayout || installing
            widths.append($0)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Tokens.Window.meaningPaneIdeal,
                                                 height: Tokens.Window.mainMinimumHeight),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = probe
        probe.needsLayout = true
        probe.layoutSubtreeIfNeeded()
        installing = false
        #expect(!changedDuringLayout, "a synchronous callback feeds SwiftUI state back into native layout")
        for _ in 0..<20 where widths.isEmpty { await Task.yield() }
        #expect(!widths.isEmpty, "the visible width must still be reported after layout")
        window.contentView = nil
        window.close()
    }
}

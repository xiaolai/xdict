import AppKit
import Testing
@testable import XDictEntryView

/// **Where the entry sits in its pane**: no band above it while the find bar is hidden, and a reading inset no
/// dictionary's stylesheet removes. Laid out without a window; no web view is made.
@MainActor
struct LayoutTests {
    private func laidOut(_ controller: EntryViewController) -> NSView {
        let root = controller.view
        root.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        root.layoutSubtreeIfNeeded()
        return root
    }

    @Test func theEntryStartsAtThePaneTopWhileFindIsHidden() {
        let controller = EntryViewController()
        let root = laidOut(controller)
        #expect(controller.container.frame.maxY == root.bounds.maxY, "the hidden find bar kept its height")
        #expect(controller.container.frame.height == root.bounds.height)
    }

    @Test func theFindBarPushesTheEntryDownOnlyWhileShown() {
        let controller = EntryViewController()
        let root = laidOut(controller)
        controller.showFind()
        root.layoutSubtreeIfNeeded()
        #expect(controller.container.frame.maxY < root.bounds.maxY)
        controller.hideFind()
        root.layoutSubtreeIfNeeded()
        #expect(controller.container.frame.maxY == root.bounds.maxY)
    }

    /// Many MDict stylesheets say `body{margin:0}` (GoldenDict pads its articles itself). The inset is the root's
    /// padding, `!important`, so a body margin, or a plain `html{padding:0}`, cannot take it away; it rides in the
    /// appearance stylesheet the shell already writes, for both schemes. Its computed effect is the E2E check
    /// `ax.entryInset`, on an entry whose own CSS says `body{margin:0}`.
    @Test func everyEntryGetsAReadingInsetThatABodyMarginCannotRemove() throws {
        let inset = EntryScripts.readingInset
        #expect(inset.hasPrefix("html{"))
        #expect(!inset.contains("body"))
        let padding = try #require(inset.firstMatch(of: /padding:(\d+)px (\d+)px !important/))
        #expect(Int(padding.output.1).map { $0 >= 8 } == true)
        #expect(Int(padding.output.2).map { $0 >= 8 } == true)
        for scheme in [EntryColourScheme.light, .dark] {
            #expect(EntryScripts.appearance(scheme).contains(inset), "\(scheme)")
        }
    }
}

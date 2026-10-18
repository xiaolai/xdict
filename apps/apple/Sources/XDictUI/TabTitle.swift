import AppKit
import SwiftUI

/// **A tab's label, apart from the window's title.** The window keeps "XDict" in its title bar (P2); each tab names the
/// word it shows. SwiftUI's `navigationTitle` sets the window's title, which a tab otherwise copies, so every tab read
/// "XDict" (owner, 2026-10-18). `NSWindow.tab.title` overrides the copy for the tab only.
struct TabTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TabTitleView {
        let view = TabTitleView()
        view.title = title
        return view
    }

    func updateNSView(_ view: TabTitleView, context: Context) { view.title = title }
}

final class TabTitleView: NSView {
    var title = "" { didSet { apply() } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        guard let window, window.tab.title != title else { return }
        window.tab.title = title
    }
}

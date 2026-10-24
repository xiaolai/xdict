import AppKit
import SwiftUI
import Testing
@testable import XDictUI

/// **The main window's toolbar in an offscreen window**, for the tests that lay out the real window frame
/// (`MeaningPaneFitTests`). The search field is SwiftUI's `.searchable` (owner, 2026-10-24), placed and sized by the
/// system, so nothing here lays out a field: the toolbar's own items are Back/Forward, the speaker and the text-size
/// pair, plus the answer pane's toggle where a test adds it.
@MainActor
struct ToolbarTestSupport {
    /// The main window's frame around `SearchToolbar`: what `SearchWindow` puts around it, with a sidebar of headwords
    /// or none and the title's count line as given.
    struct Frame: View {
        let sidebar: Bool
        let subtitle: String
        // Wide until the first layout measures it, as the main window's (`Tokens.Window.initialColumn`): the title shows.
        @State private var column = CGFloat.infinity

        var body: some View {
            NavigationSplitView(columnVisibility: .constant(sidebar ? .all : .detailOnly)) {
                List(0..<20, id: \.self) { Text(verbatim: "headword \($0)") }
                    .toolbar(removing: .sidebarToggle)
                    .navigationSplitViewColumnWidth(min: ToolbarLayout.sidebar.min, ideal: ToolbarLayout.sidebar.ideal,
                                                    max: ToolbarLayout.sidebar.max)
            } detail: {
                Color.clear
                    .frame(minWidth: ToolbarLayout.minimumWindow.width / 2)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { column = $0 }
            }
            .toolbar {
                SearchToolbar(canGoBack: true, canGoForward: true, canPronounce: true, back: {}, forward: {},
                              smaller: {}, bigger: {}, pronounce: {})
            }
            .toolbar(removing: ToolbarLayout.titleYields(width: column) ? .title : nil)
            .navigationTitle(Text(ToolbarLayout.windowTitle))
            .navigationSubtitle(Text(verbatim: subtitle))
        }
    }

    /// Half a point: a rounding, not an overlap.
    static let tolerance: CGFloat = 0.5

    /// One shown toolbar item: where it is in the window.
    struct Shown {
        let frame: NSRect
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    static func window(sidebar: Bool, subtitle: String, style: NSWindow.ToolbarStyle = .unified) -> NSWindow {
        let host = NSHostingController(rootView: Frame(sidebar: sidebar, subtitle: subtitle))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .closable, .miniaturizable]
        window.toolbarStyle = style
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: ToolbarLayout.minimumWindow.width,
                                       height: ToolbarLayout.minimumWindow.height)
        return window
    }

    /// Lets AppKit and SwiftUI settle: layout passes with the run loop turning between them.
    static func settle(_ window: NSWindow) async throws {
        for _ in 0..<3 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func resize(_ window: NSWindow, to width: CGFloat) async throws {
        window.setContentSize(NSSize(width: width, height: ToolbarLayout.minimumWindow.height))
        try await settle(window)
    }

    /// The shown items, and the labels of those in the overflow.
    static func items(_ window: NSWindow) -> (shown: [Shown], overflow: [String]) {
        guard let toolbar = window.toolbar else { return ([], []) }
        let visible = Set((toolbar.visibleItems ?? []).map(ObjectIdentifier.init))
        var shown: [Shown] = []
        var overflow: [String] = []
        for item in toolbar.items {
            guard let view = item.view else { continue }
            guard visible.contains(ObjectIdentifier(item)), view.window === window else {
                overflow.append(item.label)
                continue
            }
            shown.append(Shown(frame: view.convert(view.bounds, to: nil)))
        }
        return (shown, overflow)
    }

    /// The toolbar's own items show, in order, without overlapping.
    @Test func theToolbarsOwnItemsShowWithoutOverlap() async throws {
        let window = Self.window(sidebar: false, subtitle: "")
        defer { window.close() }
        try await Self.resize(window, to: 900)
        let (shown, _) = Self.items(window)
        #expect(shown.count == 3, "Back/Forward, Pronounce and Text Size")
        for (index, item) in shown.enumerated() {
            for other in shown[(index + 1)...] {
                #expect(item.frame.intersection(other.frame).width <= Self.tolerance,
                        "two items overlap: \(item.frame) and \(other.frame)")
                #expect(item.frame.minX < other.frame.minX, "the toolbar's order changed")
            }
        }
    }
}

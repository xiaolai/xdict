import AppKit
import SwiftUI
import Testing
import XDictSearch
import XDictTestSupport
@testable import XDictUI

/// **The main window's toolbar fits at every width** (owner, 2026-10-19: stretching the window slid the speaker over the
/// search field and ran the field past the window's edge). `SearchToolbar`'s own items, with the real search field, in
/// a window laid out as the main window is (the sidebar, its widths, the title that yields: `SearchWindow`), are
/// widened from the 400 pt minimum and narrowed back, in small steps: no two shown items overlap, none leaves the
/// window, the field stays in the toolbar (P8), keeps its order, and is as wide as the window asks (P5) whenever
/// nothing went to the overflow. The window is never shown: AppKit lays out its toolbar all the same.
@MainActor
struct ToolbarFitTests {
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
                              smaller: {}, bigger: {}, pronounce: {},
                              field: SearchWindow.searchField(text: "", known: [], scope: .all, focus: 0,
                                                              onScope: { _ in }, onChange: { _ in }, onSubmit: {},
                                                              onMove: { _ in false }, onCancel: { false }))
            }
            .toolbar(removing: ToolbarLayout.titleYields(width: column) ? .title : nil)
            .navigationTitle(Text(ToolbarLayout.windowTitle))
            .navigationSubtitle(Text(verbatim: subtitle))
        }
    }

    /// Half a point: a rounding, not an overlap.
    static let tolerance: CGFloat = 0.5
    /// The sweep: from the least the window takes to a window wider than the field ever grows for, in 10 pt steps.
    static let widest: CGFloat = 2400
    static let step: CGFloat = 10

    /// One shown toolbar item: where it is in the window, and whether it holds the search field.
    struct Shown {
        let frame: NSRect
        let field: NSRect?
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    /// Lets AppKit and SwiftUI settle: layout passes with the run loop turning between them (the field's width and
    /// priority are set on the next turn after a resize, as in the app).
    static func settle(_ window: NSWindow) async throws {
        for _ in 0..<4 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The toolbar's items that are shown (not in the overflow), in the toolbar's order.
    static func shown(_ window: NSWindow) -> (shown: [Shown], hidden: Int) {
        guard let toolbar = window.toolbar else { return ([], 0) }
        let visible = Set((toolbar.visibleItems ?? []).map(ObjectIdentifier.init))
        var shown: [Shown] = []
        var hidden = 0
        for item in toolbar.items {
            guard let view = item.view else { continue }
            guard visible.contains(ObjectIdentifier(item)), view.window === window else {
                hidden += 1
                continue
            }
            let field = find(NSSearchField.self, in: view).map { $0.convert($0.bounds, to: nil) }
            shown.append(Shown(frame: view.convert(view.bounds, to: nil), field: field))
        }
        return (shown, hidden)
    }

    /// Every way the toolbar must not break at one width; each failure names the width and the case. Answers how many
    /// items were shown and how many went to the overflow, so a sweep can tell it saw a toolbar at all.
    @discardableResult
    static func check(_ window: NSWindow, width: CGFloat, sidebar: Bool, label: String) -> (shown: Int, hidden: Int) {
        let (items, hidden) = shown(window)
        let at = "\(label), \(sidebar ? "sidebar" : "no sidebar"), \(Int(width)) pt"
        let tolerance = Self.tolerance
        guard let field = items.first(where: { $0.field != nil }), let box = field.field else {
            Issue.record("the search field is not in the toolbar (P8) at \(at)")
            return (items.count, hidden)
        }
        for (index, item) in items.enumerated() {
            #expect(item.frame.minX >= -tolerance && item.frame.maxX <= width + tolerance,
                    "an item leaves the window at \(at): \(item.frame)")
            for other in items[(index + 1)...] {
                let overlap = item.frame.intersection(other.frame)
                #expect(overlap.isNull || overlap.width <= tolerance,
                        "two items overlap at \(at): \(item.frame) and \(other.frame)")
                #expect(item.frame.minX < other.frame.minX, "the toolbar's order changed at \(at)")
            }
        }
        #expect(box.minX >= field.frame.minX - tolerance && box.maxX <= field.frame.maxX + tolerance,
                "the search field spills out of its item at \(at): \(box) in \(field.frame)")
        #expect(box.width >= ToolbarLayout.searchWidth.min - tolerance
                    && box.width <= ToolbarLayout.searchWidth.max + tolerance,
                "the search field is \(box.width) pt at \(at)")
        if hidden == 0 {
            #expect(abs(box.width - ToolbarLayout.searchFieldWidth(window: width)) <= tolerance,
                    "with room for everything, the field is \(box.width) pt, not P5's width, at \(at)")
        }
        return (items.count, hidden)
    }

    /// Widens a window step by step from the least it takes to well past the field's most, then narrows it back: a
    /// width the toolbar measured once and kept is caught on the way out or on the way back.
    static func sweep(sidebar: Bool, subtitle: String, label: String) async throws {
        let host = NSHostingController(rootView: Frame(sidebar: sidebar, subtitle: subtitle))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .closable, .miniaturizable]
        window.contentMinSize = NSSize(width: ToolbarLayout.minimumWindow.width,
                                       height: ToolbarLayout.minimumWindow.height)
        defer { window.close() }
        let out = Array(stride(from: ToolbarLayout.minimumWindow.width, through: widest, by: step))
        try await settle(window)
        for width in out + out.reversed() {
            window.setContentSize(NSSize(width: width, height: ToolbarLayout.minimumWindow.height))
            try await settle(window)
            // A sidebar makes the window wider than asked at the least: check the width it took.
            let seen = check(window, width: window.frame.width, sidebar: sidebar, label: label)
            // The widest window shows every item (Back/Forward, the text-size pair, the speaker, the field): the checks
            // above ran over a whole toolbar, not an empty one.
            if width == widest { #expect(seen.shown >= 4 && seen.hidden == 0, "at \(Int(width)) pt: \(seen)") }
        }
    }

    @Test(arguments: [false, true])
    func theToolbarFitsAtEveryWidthInEnglish(sidebar: Bool) async throws {
        let count = try CompiledCatalog.text(#require(ToolbarLayout.subtitle(found: 66_355)), in: "en")
        try await Self.sweep(sidebar: sidebar, subtitle: count, label: "en")
    }

    @Test(arguments: [false, true])
    func theToolbarFitsAtEveryWidthInChinese(sidebar: Bool) async throws {
        let count = try CompiledCatalog.text(#require(ToolbarLayout.subtitle(found: 66_355)), in: "zh-Hans")
        try await Self.sweep(sidebar: sidebar, subtitle: count, label: "zh-Hans")
    }

    /// No count line at all (before a search): the title alone.
    @Test func theToolbarFitsWithTheTitleAlone() async throws {
        try await Self.sweep(sidebar: false, subtitle: "", label: "title alone")
    }
}

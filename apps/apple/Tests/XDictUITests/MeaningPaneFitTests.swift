import AppKit
import SwiftUI
import Testing
import XDictSearch
import XDictTokens
@testable import XDictUI

/// **The main window with the answer asked for** (native capture, 2026-10-23: at 1180 × 760 pt with the pane open the
/// toolbar showed only the speaker and the title and sent Back/Forward, Text Size and the search field to the overflow;
/// at 400 × 300 pt opening the pane aborted in a recursive constraint update). `SearchToolbar`'s own items with the
/// real search field, in the frame `SearchWindow` and its scene put around them, checked as the window lays them out:
///
/// - where the answer opens beside the entry (`MeaningPlacement.inspector`): the pane is shown, every toolbar item
///   is in its own place with no neighbour over it, the field is shown (P8) and, with room for every item, P5's width;
/// - where it does not (`.sheet`): no inspector is laid out, so nothing widens the window. The sheet itself is modal and
///   is checked on screen (an offscreen window presents none);
/// - no width, no opening or closing and no crossing between the two moves the window's width or the results list.
@MainActor
struct MeaningPaneFitTests {
    /// What the reader asked for, and what the window laid out, measured by SwiftUI in the window's coordinates.
    @MainActor @Observable final class Measured {
        var open = true
        var results = true
        @ObservationIgnored var presentation: MeaningPlacement = .hidden
        @ObservationIgnored var entry: CGRect = .null
        /// An AppKit view in the inspector's content: SwiftUI keeps a collapsed inspector's content, and its last
        /// measured frame with it, so what is on screen is read from AppKit (`paneShown`).
        @ObservationIgnored let pane = NSView()
    }

    struct Marker: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    /// The inspector is on screen: its content in this window, under no hidden view (a collapsed split item is
    /// hidden), and at least the pane's least of it inside the window.
    static func paneShown(_ window: NSWindow, _ measured: Measured) -> Bool {
        let pane = measured.pane
        guard pane.window === window, !pane.isHiddenOrHasHiddenAncestor, let content = window.contentView else { return false }
        let inside = pane.convert(pane.bounds, to: nil).intersection(content.convert(content.bounds, to: nil))
        return !inside.isNull && inside.width >= Tokens.Window.meaningPaneMin - tolerance
    }

    /// Layout settled and the inspector's slide finished, so a width or a pane is read after AppKit's last move.
    static func settled(_ window: NSWindow) async throws {
        try await ToolbarFitTests.settle(window)
        try await Task.sleep(for: .milliseconds(500))
        try await ToolbarFitTests.settle(window)
    }

    /// `SearchWindow`'s frame around the toolbar, inside `XDictApp`'s scene frame.
    struct Frame: View {
        let measured: Measured
        @State private var column = CGFloat.infinity
        @State private var width: CGFloat?

        var body: some View {
            let shown = MeaningPlacement.at(width: width, results: measured.results, meaning: measured.open)
            NavigationSplitView(columnVisibility: .constant(measured.results ? .all : .detailOnly)) {
                List(0..<20, id: \.self) { Text(verbatim: "headword \($0)") }
                    .toolbar(removing: .sidebarToggle)
                    .navigationSplitViewColumnWidth(min: ToolbarLayout.sidebar.min, ideal: ToolbarLayout.sidebar.ideal,
                                                    max: ToolbarLayout.sidebar.max)
            } detail: {
                // The entry column's own content asks for more than any least, as the meaning row's controls do.
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack { actions }
                }
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    column = $0.width
                    measured.entry = $0
                }
                .inspector(isPresented: .constant(shown == .inspector)) {
                    Marker(view: measured.pane)
                        .toolbar { MeaningPaneToggle(shown: measured.open, toggle: {}) }
                        .inspectorColumnWidth(min: Tokens.Window.meaningPaneMin, ideal: Tokens.Window.meaningPaneIdeal,
                                              max: Tokens.Window.meaningPaneMax)
                }
            }
            .toolbar {
                SearchToolbar(canGoBack: true, canGoForward: true, canPronounce: true, back: {}, forward: {},
                              smaller: {}, bigger: {}, pronounce: {},
                              field: SearchWindow.searchField(text: "", known: [], scope: .all, focus: 0,
                                                              onScope: { _ in }, onChange: { _ in }, onSubmit: {},
                                                              onMove: { _ in false }, onCancel: { false }))
            }
            .toolbar(removing: ToolbarLayout.titleYields(width: column) ? .title : nil)
            .navigationTitle(Text(verbatim: "apple"))
            .navigationSubtitle(Text(verbatim: "1 found"))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: shown, initial: true) { measured.presentation = shown }
            // `XDictApp`'s window minimum around `MainWindow` (parity P1): AppKit's, not a SwiftUI frame's.
            .frame(minWidth: 0, minHeight: 0)
            .background(WindowMinimum(ToolbarLayout.minimumWindow))
        }

        @ViewBuilder private var actions: some View {
            Button("Meaning Here") {}
            Button("Preview the Request…") {}
            Button("Explain This Sense") {}
            Button("Clear Choice") {}
        }
    }

    static func window(_ measured: Measured, width: CGFloat, open: Bool, results: Bool) async throws -> NSWindow {
        measured.open = open
        measured.results = results
        let host = NSHostingController(rootView: Frame(measured: measured))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .closable, .miniaturizable]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        try await ToolbarFitTests.resize(window, to: width)
        try await settled(window)
        return window
    }

    static let tolerance = ToolbarFitTests.tolerance
    static let room = ToolbarLayout.minimumWindow.width / 2
    static let pane = Tokens.Window.meaningPaneIdeal
    static let list = ToolbarLayout.sidebar.ideal

    /// The window's width is the one asked for, the presentation the policy's for it, the inspector laid out exactly
    /// when it is the policy's, and the search field in the toolbar with no neighbour over it.
    static func check(_ window: NSWindow, _ measured: Measured, width: CGFloat, at: String) {
        #expect(abs(window.frame.width - width) <= tolerance, "the window is \(window.frame.width) pt at \(at)")
        let expected = MeaningPlacement.at(width: window.frame.width, results: measured.results, meaning: measured.open)
        #expect(measured.presentation == expected, "presented \(measured.presentation), not \(expected), at \(at)")
        let inspector = paneShown(window, measured)
        let frame = measured.pane.convert(measured.pane.bounds, to: nil)
        #expect(inspector == (expected == .inspector),
                "the inspector is \(inspector ? "shown" : "not shown") (\(frame), hidden \(measured.pane.isHiddenOrHasHiddenAncestor)) at \(at)")
        #expect(measured.entry.width > 0, "the entry column is gone at \(at)")
        let (shown, overflow) = ToolbarFitTests.items(window)
        guard let field = shown.lazy.compactMap(\.field).first else {
            Issue.record("the search field went to the overflow at \(at): \(shown.count) shown, overflow \(overflow)")
            return
        }
        #expect(field.minX >= 0 && field.maxX <= window.frame.width + tolerance, "the field \(field) leaves the window at \(at)")
        // The toggle stays where the reader reaches it, the answer beside the entry, in a sheet or closed (UI05).
        #expect(toggleShown(window), "the answer's toggle left the toolbar at \(at)")
        let title = measured.open ? "Hide Meaning in Context" : "Show Meaning in Context"
        #expect(toggleLabels(window) == [title], "the toggle reads \(toggleLabels(window)), not \(title), at \(at)")
        let frames = shown.map(\.frame)
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                #expect(a.intersection(b).width <= tolerance, "toolbar items \(a) and \(b) overlap at \(at)")
            }
        }
    }

    /// The answer's toggle is a shown toolbar item of this window, found by its label (Show or Hide Meaning in
    /// Context: SwiftUI keeps its identifier in its own accessibility elements, not on the item's view).
    static func toggleShown(_ window: NSWindow) -> Bool {
        guard let toolbar = window.toolbar else { return false }
        let visible = Set((toolbar.visibleItems ?? []).map(ObjectIdentifier.init))
        return toolbar.items.contains { item in
            visible.contains(ObjectIdentifier(item)) && item.view?.window === window
                && item.label.hasSuffix("Meaning in Context")
        }
    }

    /// The labels of the answer's toggles in the toolbar.
    static func toggleLabels(_ window: NSWindow) -> [String] {
        (window.toolbar?.items ?? []).map(\.label).filter { $0.hasSuffix("Meaning in Context") }
    }

    /// **The first search's results list keeps the reader's width** (native capture `main.meaningCompactReopened`,
    /// 2026-10-23: a 400 pt window before its first lookup was 584 pt once the lookup brought the list): the list comes
    /// at 400 pt and the window stays 400 pt, and so it does as the reader hides and restores it, with the answer
    /// closed and in its sheet.
    @Test func theFirstResultsListKeepsTheWindowsWidth() async throws {
        let width = ToolbarLayout.minimumWindow.width
        let measured = Measured()
        let window = try await Self.window(measured, width: width, open: false, results: false)
        defer { window.close() }
        Self.check(window, measured, width: width, at: "400 pt before the first search")
        try await Self.clamped(window, at: "before the first search")
        for (step, results) in [true, false, true, false, true].enumerated() {
            measured.results = results
            try await Self.settled(window)
            Self.check(window, measured, width: width, at: "400 pt, step \(step), the list \(results ? "shown" : "hidden")")
        }
        for open in [true, false, true] {
            measured.open = open
            try await Self.settled(window)
            Self.check(window, measured, width: width, at: "400 pt beside the list, the answer \(open ? "opened" : "closed")")
        }
        for (step, results) in [false, true].enumerated() {
            measured.results = results
            try await Self.settled(window)
            Self.check(window, measured, width: width, at: "400 pt with the sheet, step \(step), the list \(results ? "shown" : "hidden")")
        }
        try await Self.clamped(window, at: "with the list and the sheet")
        measured.open = false
        try await Self.settled(window)
        try await Self.clamped(window, at: "with the list")
        Self.check(window, measured, width: width, at: "400 pt with the list, after asking for 100 × 100")
    }

    /// **The window's least is Apple's 400 × 300 pt** (parity P1: asked for 100 × 100, Apple's took 400 × 300), a frame
    /// including its title bar and toolbar, kept whatever the panes ask.
    static func clamped(_ window: NSWindow, at: String) async throws {
        window.setContentSize(NSSize(width: 100, height: 100))
        try await settled(window)
        let least = ToolbarLayout.minimumWindow
        #expect(abs(window.frame.width - least.width) <= tolerance && abs(window.frame.height - least.height) <= tolerance,
                "asked for 100 × 100 \(at), the window is \(window.frame.size), not \(least.width) × \(least.height)")
    }

    /// **Beside the entry, the toolbar keeps every item in its place**: the pane's toggle at the trailing end, the field
    /// before it at P5's width when everything fits, and at the capture's 1180 pt and wider nothing in the overflow.
    @Test(arguments: [false, true])
    func theInspectorLeavesTheToolbarItsPlaces(results: Bool) async throws {
        let least = Self.room + Self.pane + (results ? Self.list : 0)
        let measured = Measured()
        let window = try await Self.window(measured, width: 1180, open: true, results: results)
        defer { window.close() }
        for width: CGFloat in [least, 800, 1000, 1180, 1400, 2400, 1180, 800, least] {
            try await ToolbarFitTests.resize(window, to: width)
            try await Self.settled(window)
            let at = "\(Int(width)) pt with the answer beside the entry" + (results ? " and the results" : "")
            Self.check(window, measured, width: width, at: at)
            let (shown, overflow) = ToolbarFitTests.items(window)
            if width >= 1180 {
                #expect(overflow.isEmpty, "with room for every item, \(overflow) went to the overflow at \(at)")
            }
            if overflow.isEmpty, let field = shown.lazy.compactMap(\.field).first {
                #expect(abs(field.width - ToolbarLayout.searchFieldWidth(window: window.frame.width)) <= Self.tolerance,
                        "the field is \(field.width) pt, not P5's width for the \(window.frame.width) pt window, at \(at)")
            }
        }
    }

    /// **Every width, back and forth across the sheet's edge, keeps the window's width** (the 400 × 300 pt abort; the
    /// earlier policy's 400 → 583 → 843 pt growth): the reader's results list stays as they left it throughout.
    @Test(arguments: [false, true])
    func noWidthGrowsTheWindow(results: Bool) async throws {
        let least = Self.room + Self.pane + (results ? Self.list : 0)
        let measured = Measured()
        let window = try await Self.window(measured, width: ToolbarLayout.minimumWindow.width, open: true, results: results)
        defer { window.close() }
        for (step, width): (Int, CGFloat) in [400, 450, least - 1, least, 1180, least - 1, 600, 400, 2400, 400].enumerated() {
            try await ToolbarFitTests.resize(window, to: width)
            try await Self.settled(window)
            Self.check(window, measured, width: width,
                       at: "\(Int(width)) pt with the answer asked for" + (results ? " beside the results" : "") + ", step \(step)")
        }
    }

    /// **Opening and closing the answer keeps the window's width** (native capture `main.meaningAnswerNarrow`: ⌘⌥↓ at
    /// 400 × 300 pt aborted), in the sheet's width and in the inspector's, with and without the results list.
    @Test(arguments: [false, true], [CGFloat(400), 1180])
    func openingAndClosingTheAnswerKeepsTheWindowsWidth(results: Bool, width: CGFloat) async throws {
        let measured = Measured()
        let window = try await Self.window(measured, width: width, open: false, results: results)
        defer { window.close() }
        #expect(abs(window.frame.width - width) <= Self.tolerance, "the window opened at \(window.frame.width) pt")
        for open in [true, false, true, false] {
            measured.open = open
            try await Self.settled(window)
            Self.check(window, measured, width: width, at: "\(Int(width)) pt with the answer \(open ? "opened" : "closed")"
                       + (results ? " beside the results" : ""))
        }
    }
}

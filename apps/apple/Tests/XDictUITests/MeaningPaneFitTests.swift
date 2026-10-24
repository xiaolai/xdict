import AppKit
import SwiftUI
import Testing
import XDictSearch
import XDictTokens
@testable import XDictUI

/// The production outward-resize bridge with the native inspector and toolbar in an offscreen AppKit window.
/// Opening preserves the entry, repeated closes restore the frame, and a screen with no room uses a sheet.
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
        @State private var shown: MeaningPlacement = .hidden
        @State private var paneWidth = Tokens.Window.meaningPaneIdeal

        var body: some View {
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
                        .inspectorColumnWidth(min: Tokens.Window.meaningPaneMin, ideal: paneWidth,
                                              max: Tokens.Window.meaningPaneMax)
                        .background(VisibleWidth {
                            if measured.open, shown == .inspector, $0 >= Tokens.Window.meaningPaneMin { paneWidth = $0 }
                        })
                }
            }
            .toolbar {
                SearchToolbar(canGoBack: true, canGoForward: true, canPronounce: true, back: {}, forward: {},
                              smaller: {}, bigger: {}, pronounce: {},
                              field: SearchWindow.searchField(text: "sample", known: [], scope: .all, focus: 0,
                                                              onScope: { _ in }, onChange: { _ in }, onSubmit: {},
                                                              onMove: { _ in false }, onCancel: { false }))
                MeaningPaneToggle(shown: measured.open, toggle: {})
            }
            .toolbar(removing: ToolbarLayout.titleYields(width: column) ? .title : nil)
            .navigationTitle(Text(verbatim: "apple"))
            .navigationSubtitle(Text(verbatim: "1 found"))
            .background(OutwardPane(shown: measured.open, width: paneWidth, presentation: $shown))
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
        measured.open = false
        measured.results = results
        let host = NSHostingController(rootView: Frame(measured: measured))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .closable, .miniaturizable]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        try await ToolbarFitTests.resize(window, to: width)
        try await settled(window)
        if open {
            measured.open = true
            try await settled(window)
        }
        return window
    }

    static let tolerance = ToolbarFitTests.tolerance
    static let pane = Tokens.Window.meaningPaneIdeal

    @Test(arguments: [false, true], [CGFloat(400), 800])
    func openingTheAnswerAddsRoomWithoutTakingItFromTheEntry(results: Bool, width: CGFloat) async throws {
        let measured = Measured()
        let window = try await Self.window(measured, width: width, open: false, results: results)
        defer { window.close() }
        if let screen = window.screen {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: window.frame.minY))
        }
        let original = window.frame
        let entry = measured.entry.width
        for _ in 0..<3 {
            measured.open = true
            try await Self.settled(window)
            #expect(abs(window.frame.width - original.width - Self.pane) <= Self.tolerance)
            #expect(abs(measured.entry.width - entry) <= Self.tolerance,
                    "opening took room from the entry: \(entry) → \(measured.entry.width)")
            #expect(abs(window.frame.minX - original.minX) <= Self.tolerance)
            #expect(abs(window.frame.height - original.height) <= Self.tolerance)
            #expect(Self.paneShown(window, measured))
            measured.open = false
            try await Self.settled(window)
            #expect(abs(window.frame.width - original.width) <= Self.tolerance)
            #expect(abs(measured.entry.width - entry) <= Self.tolerance)
        }
    }

    @Test(arguments: [false, true])
    func resultsVisibilityDoesNotResizeTheWindow(open: Bool) async throws {
        let measured = Measured()
        let window = try await Self.window(measured, width: 400, open: open, results: false)
        defer { window.close() }
        let width = window.frame.width
        for results in [true, false, true, false, true] {
            measured.results = results
            try await Self.settled(window)
            #expect(abs(window.frame.width - width) <= Self.tolerance)
            #expect(measured.results == results)
            #expect(Self.paneShown(window, measured) == open)
        }
    }

    @Test func aScreenFillingWindowUsesTheSheetWithoutCompressingTheEntry() async throws {
        let measured = Measured()
        let window = try await Self.window(measured, width: 800, open: false, results: true)
        defer { window.close() }
        let screen = try #require(window.screen)
        try await ToolbarFitTests.resize(window, to: screen.visibleFrame.width)
        try await Self.settled(window)
        let original = window.frame
        let entry = measured.entry.width
        measured.open = true
        try await Self.settled(window)
        #expect(measured.presentation == .sheet)
        #expect(!Self.paneShown(window, measured))
        #expect(window.frame == original)
        #expect(abs(measured.entry.width - entry) <= Self.tolerance)
        measured.open = false
        try await Self.settled(window)
        #expect(window.frame == original)
    }

    @Test func openingAtTheScreenEdgeMovesOnlyAsFarAsNeededAndClosingRestoresIt() async throws {
        let measured = Measured()
        let window = try await Self.window(measured, width: 800, open: false, results: true)
        defer { window.close() }
        let screen = try #require(window.screen)
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - window.frame.width, y: window.frame.minY))
        let original = window.frame
        let entry = measured.entry.width
        measured.open = true
        try await Self.settled(window)
        #expect(abs(window.frame.maxX - original.maxX) <= Self.tolerance)
        #expect(abs(window.frame.minX - original.minX + Self.pane) <= Self.tolerance)
        #expect(abs(measured.entry.width - entry) <= Self.tolerance)
        measured.open = false
        try await Self.settled(window)
        #expect(window.frame == original)
    }

    @Test func closingKeepsAReadersLaterResizeAndMove() async throws {
        let measured = Measured()
        let window = try await Self.window(measured, width: 800, open: true, results: true)
        defer { window.close() }
        try await ToolbarFitTests.resize(window, to: 900 + Self.pane)
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 10, y: window.frame.minY))
        try await Self.settled(window)
        let entry = measured.entry.width
        let origin = window.frame.origin
        measured.open = false
        try await Self.settled(window)
        #expect(abs(window.frame.width - 900) <= Self.tolerance)
        #expect(window.frame.origin == origin)
        #expect(abs(measured.entry.width - entry) <= Self.tolerance)
    }

    @Test func resizingBelowTheInspectorsMinimumUsesTheSheetAtTheRequestedWidth() async throws {
        let measured = Measured()
        let window = try await Self.window(measured, width: 800, open: true, results: true)
        defer { window.close() }
        try await ToolbarFitTests.resize(window, to: 400)
        try await Self.settled(window)
        #expect(abs(window.frame.width - 400) <= Self.tolerance)
        #expect(measured.presentation == .sheet)
        #expect(!Self.paneShown(window, measured))
        measured.open = false
        try await Self.settled(window)
        #expect(abs(window.frame.width - 400) <= Self.tolerance)
    }

    /// Reopening from the dismissal callback precedes the deferred contraction; the reserved room is reused.
    @Test func reopeningBeforeTheDeferredContractionDoesNotAddThePaneTwice() async throws {
        let probe = OutwardPane.Probe()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 100, width: 800, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = probe
        defer { window.close() }
        let original = window.frame
        probe.shown = true
        probe.schedule()
        try await Self.settled(window)
        #expect(abs(window.frame.width - original.width - Self.pane) <= Self.tolerance)
        probe.changed = { presentation in
            if presentation == .hidden {
                probe.shown = true
                probe.schedule()
            }
        }
        defer { probe.changed = nil }
        probe.shown = false
        probe.schedule()
        try await Self.settled(window)
        #expect(abs(window.frame.width - original.width - Self.pane) <= Self.tolerance)
        probe.changed = nil
        probe.shown = false
        probe.schedule()
        try await Self.settled(window)
        #expect(abs(window.frame.width - original.width) <= Self.tolerance)
    }

    @Test(arguments: [false, true])
    func theInspectorLeavesTheToolbarItsPlaces(results: Bool) async throws {
        let measured = Measured()
        let window = try await Self.window(measured, width: 800, open: true, results: results)
        defer { window.close() }
        for width: CGFloat in [800, 1000, 1180, 1400, 1180, 800] {
            try await ToolbarFitTests.resize(window, to: width)
            try await Self.settled(window)
            #expect(abs(window.frame.width - width) <= Self.tolerance)
            #expect(Self.paneShown(window, measured))
            #expect(measured.entry.width > 0)
            let (shown, overflow) = ToolbarFitTests.items(window)
            let field = try #require(shown.lazy.compactMap(\.field).first, "the search field went to overflow: \(overflow)")
            #expect(field.minX >= 0 && field.maxX <= width + Self.tolerance)
            let labels = (window.toolbar?.visibleItems ?? []).map(\.label)
            #expect(labels.contains("Hide Meaning in Context"))
            if width >= 1180 { #expect(overflow.isEmpty) }
            for (index, first) in shown.enumerated() {
                for second in shown[(index + 1)...] {
                    #expect(first.frame.intersection(second.frame).width <= Self.tolerance)
                }
            }
        }
    }

    @Test(arguments: [CGFloat(260), 460])
    func changingThePaneWidthKeepsTheReservationAndRestoresTheOriginalWindow(paneWidth: CGFloat) async throws {
        let probe = OutwardPane.Probe()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 100, width: 400, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = probe
        defer { window.close() }
        let original = window.frame
        probe.shown = true
        probe.schedule()
        try await Self.settled(window)
        probe.paneWidth = paneWidth
        probe.schedule()
        try await Self.settled(window)
        #expect(abs(window.frame.width - original.width - paneWidth) <= Self.tolerance)
        probe.shown = false
        probe.schedule()
        try await Self.settled(window)
        #expect(window.frame == original)
    }

    @Test func aFailedFullScreenEntryDoesNotLeaveThePaneDisabled() async throws {
        let probe = OutwardPane.Probe()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 100, width: 800, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = probe
        defer { window.close() }
        let original = window.frame
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        probe.shown = true
        probe.schedule()
        try await Self.settled(window)
        #expect(abs(window.frame.width - original.width - Self.pane) <= Self.tolerance)
    }

    @Test func aPaneThatOutgrowsTheScreenRestoresTheBaseFrameBeforeUsingTheSheet() async throws {
        let probe = OutwardPane.Probe()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 100, width: 400, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = probe
        defer { window.close() }
        let screen = try #require(window.screen)
        var frame = window.frame
        frame.size.width = screen.visibleFrame.width - Self.pane
        frame.origin.x = screen.visibleFrame.minX
        window.setFrame(frame, display: true)
        let original = window.frame
        var presentation: MeaningPlacement = .hidden
        probe.changed = { presentation = $0 }
        probe.shown = true
        probe.schedule()
        try await Self.settled(window)
        #expect(presentation == .inspector)
        probe.paneWidth = Tokens.Window.meaningPaneMax
        probe.schedule()
        try await Self.settled(window)
        #expect(presentation == .sheet)
        #expect(window.frame == original)
        probe.shown = false
        probe.schedule()
        try await Self.settled(window)
        #expect(window.frame == original)
    }

    /// Notification-level lifecycle coverage; this deliberately does not claim a real fullscreen/Spaces transition.
    @Test func leavingFullScreenReconsidersTheSheetAndRestoresTheReservation() async throws {
        let probe = OutwardPane.Probe()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 100, width: 800, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = probe
        defer { window.close() }
        let original = window.frame
        var presentation: MeaningPlacement = .hidden
        probe.changed = { presentation = $0 }
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        probe.shown = true
        probe.schedule()
        try await Self.settled(window)
        #expect(presentation == .sheet)
        #expect(window.frame == original)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        try await Self.settled(window)
        #expect(presentation == .inspector)
        #expect(abs(window.frame.width - original.width - Self.pane) <= Self.tolerance)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await Self.settled(window)
        #expect(presentation == .sheet)
        probe.shown = false
        probe.schedule()
        try await Self.settled(window)
        #expect(abs(window.frame.width - original.width - Self.pane) <= Self.tolerance)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        try await Self.settled(window)
        #expect(window.frame == original)
        #expect(presentation == .hidden)
    }
}

import AppKit
import SwiftUI
import Testing
import XDictTokens
@testable import XDictUI

/// **A Settings search result is scrolled into view** (UI30; native capture `settings.searchPrompt`, 2026-10-23: the
/// search opened AI ▸ Advanced but left Customize the Prompt at y 909 and its text at y 1039 in a window whose bottom
/// was at 806). `SettingsRevealScroll` around a grouped `.settingsPane()` Form taller than Settings' window, the row
/// below the fold, in a pane not shown when the search is made, and once inside a disclosure the reveal opens. The
/// row is checked where AppKit draws it, not where SwiftUI says it is.
@MainActor
struct SettingsRevealTests {
    /// An AppKit view in the revealed row's content: its `visibleRect` is what the scroll views leave on screen.
    struct Marker: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    /// One tall pane in the shape of AI's and Learning's: grouped sections, the revealed row (or Section) last.
    struct Pane: View {
        let route: SettingsRoute
        let anchor: SettingsSearch.Anchor
        let advanced: Bool
        let target: NSView
        @State private var open = false

        var body: some View {
            Form {
                ForEach(0..<6, id: \.self) { section in
                    Section {
                        ForEach(0..<4, id: \.self) { row in
                            Toggle(isOn: .constant(row.isMultiple(of: 2))) { Text(verbatim: "row \(section).\(row)") }
                        }
                    } header: {
                        Text(verbatim: "section \(section)")
                    }
                }
                if anchor == .history {
                    // As the real panes mark most rows: on the whole Section.
                    Section {
                        Marker(view: target).frame(height: 44)
                        Toggle(isOn: .constant(true)) { Text(verbatim: "after") }
                    } header: {
                        Text(verbatim: "last")
                    }
                    .settingsAnchor(anchor)
                } else {
                Section {
                    if advanced {
                        DisclosureGroup(isExpanded: $open) {
                            Marker(view: target).frame(height: 120)
                        } label: {
                            Text(verbatim: "Customize")
                        }
                        .settingsAnchor(anchor)
                    } else {
                        Marker(view: target).frame(height: 44)
                            .settingsAnchor(anchor)
                    }
                } header: {
                    Text(verbatim: "last")
                }
                }
            }
            .settingsPane()
            // As `AISettings` opens Advanced for its row.
            .onAppear { if route.revealed == anchor { open = true } }
            .onChange(of: route.revealSerial) { if route.revealed == anchor { open = true } }
        }
    }

    struct Detail: View {
        @Bindable var route: SettingsRoute
        let item: SettingsSearch.Item
        let target: NSView

        var body: some View {
            SettingsRevealScroll(route: route) {
                if route.pane == item.pane {
                    Pane(route: route, anchor: item.anchor, advanced: item.isAdvanced, target: target)
                } else {
                    Text(verbatim: "another pane")
                }
            }
            .frame(width: SettingsDictionaries.paneWidth, height: Tokens.Window.settingsHeight)
        }
    }

    static func settled(_ window: NSWindow) async throws {
        try await ToolbarTestSupport.settle(window)
        try await Task.sleep(for: .milliseconds(500))
        try await ToolbarTestSupport.settle(window)
    }

    /// The whole row is drawn inside the window.
    static func shown(_ target: NSView, in window: NSWindow) -> Bool {
        guard target.window === window, !target.isHiddenOrHasHiddenAncestor, target.bounds.height > 0,
              let content = window.contentView else { return false }
        let visible = target.visibleRect
        let inWindow = target.convert(target.bounds, to: nil)
        let contentRect = content.convert(content.bounds, to: nil)
        return visible.height >= target.bounds.height - ToolbarTestSupport.tolerance
            && contentRect.insetBy(dx: -ToolbarTestSupport.tolerance, dy: -ToolbarTestSupport.tolerance).contains(inWindow)
    }

    @Test(arguments: [SettingsSearch.Anchor.aiPrompt, .syncFolder, .history])
    func aRevealedRowIsScrolledIntoView(anchor: SettingsSearch.Anchor) async throws {
        let item = try #require(SettingsSearch.items.first { $0.anchor == anchor })
        let route = SettingsRoute()
        route.showPane(item.pane == .general ? .ai : .general)
        let target = NSView()
        let host = NSHostingController(rootView: Detail(route: route, item: item, target: target))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: SettingsDictionaries.paneWidth, height: Tokens.Window.settingsHeight))
        defer { window.close() }
        try await Self.settled(window)

        // Twice, another pane shown between: a repeated search is a new request, never one already used up.
        for attempt in 1...2 {
            route.reveal(item)
            try await Self.settled(window)
            let frame = target.window == nil ? CGRect.null : target.convert(target.bounds, to: nil)
            #expect(Self.shown(target, in: window),
                    "\(anchor) reveal \(attempt): the row is at \(frame), visible \(target.visibleRect), in a \(window.contentView?.bounds ?? .zero) window")
            #expect(route.revealed == nil, "\(anchor) reveal \(attempt): the request was never completed")
            route.showPane(item.pane == .general ? .ai : .general)
            try await Self.settled(window)
        }
    }

    /// **No stale request**: a reveal the reader leaves for another pane before it is shown is dropped, so the pane
    /// never jumps when they come back to it on their own.
    @Test func aRevealLeftForAnotherPaneIsDropped() throws {
        let item = try #require(SettingsSearch.items.first { $0.anchor == .aiPrompt })
        let route = SettingsRoute()
        route.reveal(item)
        route.pane = item.pane
        #expect(route.revealed == .aiPrompt, "choosing the revealed pane again keeps its request")
        route.pane = .general
        #expect(route.revealed == nil, "the request outlived the pane the reader left")
    }
}

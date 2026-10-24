import AppKit
import SwiftUI
import Testing
import XDictSearch
import XDictTestSupport
@testable import XDictUI

/// **The main window's toolbar fits at every width, however it got there** (owner, 2026-10-19: stretching the window
/// slid the speaker over the search field and ran the field past the window's edge; verifier, the same day: a jump to a
/// much narrower window sent the field to the overflow and kept it there). `SearchToolbar`'s own items, with the real
/// search field, in a window laid out as the main window is (the sidebar, its widths, the title that yields:
/// `SearchWindow`), in each toolbar style, with and without the sidebar, with an English and a Chinese count:
///
/// - widened from the 400 pt minimum and narrowed back in 10 pt steps: no two shown items overlap, none leaves the
///   window, the order holds, the field stays in the toolbar (P8) and is as wide as the window asks (P5) whenever
///   nothing went to the overflow;
/// - then jumped from every width of a grid to every other: the same checks, and the toolbar the steps left at that
///   width (which items shown, the field's width), whatever width it jumped from.
///
/// The window is never shown: AppKit lays out its toolbar all the same. A full-screen window is not: its toolbar lives
/// in a window of its own, which only a window on screen gets (`ToolbarFieldWidth` watches the main window for that).
@MainActor
struct ToolbarFitTests {
    /// The main window's frame around `SearchToolbar`: what `SearchWindow` puts around it, with a sidebar of headwords
    /// or none and the title's count line as given.
    struct Frame: View {
        let sidebar: Bool
        let subtitle: String
        var query = "sample"
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
                              field: SearchWindow.searchField(text: query, known: [], scope: .all, focus: 0,
                                                              onScope: { _ in }, onChange: { _ in }, onSubmit: {},
                                                              onMove: { _ in false }, onCancel: { false }))
            }
            .toolbar(removing: ToolbarLayout.titleYields(width: column) ? .title : nil)
            .navigationTitle(Text(ToolbarLayout.windowTitle))
            .navigationSubtitle(Text(verbatim: subtitle))
        }
    }

    /// One window to try: the sidebar, the count line, the toolbar's style.
    struct Case: CustomStringConvertible, Sendable {
        let sidebar: Bool
        let language: String
        let style: Int

        static let styles: [(String, NSWindow.ToolbarStyle)] = [("unified", .unified),
                                                                ("unifiedCompact", .unifiedCompact),
                                                                ("expanded", .expanded)]
        static let all: [Case] = styles.indices.flatMap { style in
            [false, true].flatMap { sidebar in ["en", "zh-Hans"].map { Case(sidebar: sidebar, language: $0, style: style) } }
        }

        var description: String {
            "\(language), \(sidebar ? "sidebar" : "no sidebar"), \(Self.styles[style].0)"
        }
    }

    /// Half a point: a rounding, not an overlap.
    static let tolerance: CGFloat = 0.5
    /// The sweep: from the least the window takes to a window wider than the field ever grows for, in 10 pt steps.
    static let widest: CGFloat = 2400
    static let step: CGFloat = 10
    /// The jumps: every width here to every other (un-zoom, tiling, leaving full screen, a fast drag).
    static let grid: [CGFloat] = [400, 500, 600, 700, 800, 1000, 1400, 2400]

    /// One shown toolbar item: where it is in the window, and whether it holds the search field.
    struct Shown {
        let frame: NSRect
        let field: NSRect?
    }

    /// What the toolbar shows at a width: how many items, how many in the overflow, and the field's width (nil when the
    /// field is in the overflow).
    struct Answer: Equatable, CustomStringConvertible {
        let shown: Int
        let hidden: Int
        let field: Int?
        /// The items in the overflow, by their labels (`ToolbarLabels`).
        var overflow: [String] = []

        var description: String {
            "\(shown) shown, \(hidden) hidden\(overflow.isEmpty ? "" : " (\(overflow.joined(separator: ", ")))"), "
                + "field \(field.map { "\($0) pt" } ?? "in overflow")"
        }
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    static func window(_ test: Case) throws -> NSWindow {
        let count = try CompiledCatalog.text(#require(ToolbarLayout.subtitle(found: 66_355)), in: test.language)
        return window(sidebar: test.sidebar, subtitle: count, style: Case.styles[test.style].1)
    }

    static func window(sidebar: Bool, subtitle: String, style: NSWindow.ToolbarStyle = .unified,
                       query: String = "sample") -> NSWindow {
        let host = NSHostingController(rootView: Frame(sidebar: sidebar, subtitle: subtitle, query: query))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .closable, .miniaturizable]
        window.toolbarStyle = style
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: ToolbarLayout.minimumWindow.width,
                                       height: ToolbarLayout.minimumWindow.height)
        return window
    }

    /// Lets AppKit and SwiftUI settle: layout passes with the run loop turning between them (the field's watcher is
    /// attached on the next turn after the field reaches a window, as in the app).
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

    /// The toolbar's items that are shown (not in the overflow), in the toolbar's order.
    static func shown(_ window: NSWindow) -> (shown: [Shown], hidden: Int) {
        let (shown, overflow) = items(window)
        return (shown, overflow.count)
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
            let field = find(NSSearchField.self, in: view).map { $0.convert($0.bounds, to: nil) }
            shown.append(Shown(frame: view.convert(view.bounds, to: nil), field: field))
        }
        return (shown, overflow)
    }

    /// Every way the toolbar must not break at one width; each failure names the width and the case. Answers what the
    /// toolbar shows there.
    @discardableResult
    static func check(_ window: NSWindow, at: String) -> Answer {
        let width = window.frame.width
        let (items, hidden) = shown(window)
        let at = "\(at), \(Int(width)) pt"
        let tolerance = Self.tolerance
        guard let field = items.first(where: { $0.field != nil }), let box = field.field else {
            Issue.record("the search field is not in the toolbar (P8) at \(at)")
            return Answer(shown: items.count, hidden: hidden, field: nil, overflow: Self.items(window).overflow)
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
        let least = (ToolbarLayout.searchWidth.min * 2 / 3).rounded()
        let most = (ToolbarLayout.searchWidth.max * 2 / 3).rounded()
        #expect(box.width >= least - tolerance && box.width <= most + tolerance,
                "the search field is \(box.width) pt at \(at)")
        if hidden == 0 {
            #expect(abs(box.width - ToolbarLayout.searchFieldWidth(window: width)) <= tolerance,
                    "with room for everything, the field is \(box.width) pt, not P5's width, at \(at)")
        }
        let overflow = Self.items(window).overflow
        // P48: the speaker is never the item that goes; both pairs go to the overflow before it (owner, 2026-10-19).
        if overflow.contains(String(localized: "Pronounce")) {
            #expect(overflow.contains(String(localized: "Back/Forward")) && overflow.contains(String(localized: "Text Size")),
                    "the speaker went to the overflow before a pair at \(at): \(overflow)")
        }
        return Answer(shown: items.count, hidden: hidden, field: Int(box.width.rounded()), overflow: overflow)
    }

    /// Widens step by step from the least width to the widest and back, checking each step, and answers what the
    /// toolbar showed at each grid width on the way out and on the way back.
    static func sweep(_ window: NSWindow, at: String) async throws -> (out: [CGFloat: Answer], back: [CGFloat: Answer]) {
        let out = Array(stride(from: ToolbarLayout.minimumWindow.width, through: widest, by: step))
        var answers: (out: [CGFloat: Answer], back: [CGFloat: Answer]) = ([:], [:])
        try await settle(window)
        for (index, width) in (out + out.reversed()).enumerated() {
            try await resize(window, to: width)
            let answer = check(window, at: at)
            guard grid.contains(width) else { continue }
            if index < out.count { answers.out[width] = answer } else { answers.back[width] = answer }
            // The widest window shows every item: the checks ran over a whole toolbar, not an empty one.
            if width == widest {
                #expect(answer.shown >= 4 && answer.hidden == 0, "at \(Int(width)) pt, \(at): \(answer)")
            }
        }
        return answers
    }

    /// The sweep, then every jump of the grid: each lands where the steps landed coming from the same side.
    @Test(arguments: Case.all)
    func theToolbarFitsAtEveryWidthAndAfterEveryJump(_ test: Case) async throws {
        let window = try Self.window(test)
        defer { window.close() }
        let steady = try await Self.sweep(window, at: "\(test)")
        // The steps' own answer at a width is the same widening and narrowing.
        for width in Self.grid {
            let out = steady.out[width].map(\.description) ?? "-", back = steady.back[width].map(\.description) ?? "-"
            #expect(steady.out[width] == steady.back[width],
                    "at \(Int(width)) pt, \(test): widening left \(out), narrowing \(back)")
        }
        var table: [String] = [], banded: [String] = []
        for from in Self.grid {
            for to in Self.grid where to != from {
                try await Self.resize(window, to: from)
                try await Self.resize(window, to: to)
                let got = Self.check(window, at: "\(test), jumped from \(Int(from)) pt")
                let wanted = to > from ? steady.out[to] : steady.back[to]
                let line = "\(Int(from))→\(Int(to)): \(got), the steps: \(wanted.map(\.description) ?? "-")"
                // The field as the steps leave it: in the toolbar (P8), at the same width (P5), whatever the jump.
                #expect(got.field == wanted?.field, "\(test), \(line)")
                if let wanted, Self.inBand(test, landing: to, got: got, wanted: wanted) {
                    banded.append(line)
                } else if got != wanted {
                    table.append(line)
                }
            }
        }
        let jumps = Self.grid.count * (Self.grid.count - 1)
        // Every jump leaves the toolbar the steps leave, hard, outside the band below.
        let lines = table.joined(separator: "\n")
        #expect(table.isEmpty, "\(test): \(table.count) of \(jumps) jumps left another toolbar than the steps:\n\(lines)")
        if !banded.isEmpty {
            withKnownIssue("the toolbar's keep-or-show band") {
                Issue.record("\(test): \(banded.count) of \(jumps) jumps in the band:\n\(banded.joined(separator: "\n"))")
            }
        }
    }

    /// **The toolbar's keep-or-show band** (2026-10-19, measured; accepted by the coordinator as a known issue): the
    /// toolbar keeps a shown item with less room than it needs to show a hidden one, so where an item only just fits a
    /// jump and the steps can disagree about it. Setting the field's width before the jump, removing the title, a
    /// re-layout or a 1 pt nudge do not change it. It follows the lowest item that only just fits: the speaker beside the
    /// text-size pair (494-504 pt), the speaker after Back/Forward (600-700 pt), and now, with the speaker kept above both
    /// pairs, Back/Forward. Exactly: a jump that shows Back/Forward where the steps had it in the overflow, the field the
    /// same, landing at 400 pt in the unified style or at 600 pt in the unified compact style without a sidebar. Anything
    /// else is a hard failure.
    static func inBand(_ test: Case, landing width: CGFloat, got: Answer, wanted: Answer) -> Bool {
        let style = Case.styles[test.style].0
        let pair = String(localized: "Back/Forward")
        let landing = (style == "unified" && width == 400) || (style == "unifiedCompact" && !test.sidebar && width == 600)
        return landing && got.field == wanted.field && Set(got.overflow).symmetricDifference(wanted.overflow) == [pair]
            && wanted.overflow.contains(pair)
    }

    /// **The band is exactly that** (verifier, 2026-10-19: a known issue over every setup and jump let the round-1 bug
    /// pass as known): only Back/Forward shown by the jump where the steps hid it, the field the same, at the measured
    /// landings. A lost field, the speaker, another item, the other direction, another style or width is a hard failure.
    @Test func theBandIsOnlyBackForwardAtItsMeasuredLandings() {
        let unified = Case(sidebar: true, language: "en", style: 0)
        let compact = Case(sidebar: false, language: "en", style: 1)
        let compactWithSidebar = Case(sidebar: true, language: "en", style: 1)
        let expanded = Case(sidebar: false, language: "en", style: 2)
        let pairShown = Answer(shown: 3, hidden: 1, field: 152, overflow: ["Text Size"])
        let pairHidden = Answer(shown: 2, hidden: 2, field: 152, overflow: ["Back/Forward", "Text Size"])
        #expect(Self.inBand(unified, landing: 400, got: pairShown, wanted: pairHidden))
        #expect(Self.inBand(compact, landing: 600, got: pairShown, wanted: pairHidden))
        #expect(!Self.inBand(unified, landing: 600, got: pairShown, wanted: pairHidden), "another width")
        #expect(!Self.inBand(compactWithSidebar, landing: 600, got: pairShown, wanted: pairHidden), "a sidebar")
        #expect(!Self.inBand(expanded, landing: 400, got: pairShown, wanted: pairHidden), "the expanded style")
        #expect(!Self.inBand(unified, landing: 400, got: pairHidden, wanted: pairShown), "the other direction")
        let fieldLost = Answer(shown: 2, hidden: 2, field: nil, overflow: ["Text Size", "Search"])
        #expect(!Self.inBand(unified, landing: 400, got: fieldLost, wanted: pairHidden), "the field lost")
        let speakerHidden = Answer(shown: 1, hidden: 3, field: 152, overflow: ["Back/Forward", "Pronounce", "Text Size"])
        #expect(!Self.inBand(unified, landing: 400, got: speakerHidden, wanted: pairHidden), "the speaker")
    }

    /// No count line at all (before a search): the title alone.
    @Test func theToolbarFitsWithTheTitleAlone() async throws {
        let window = Self.window(sidebar: false, subtitle: "")
        defer { window.close() }
        _ = try await Self.sweep(window, at: "title alone")
    }

    /// **The preferred width's priority** (verifier, 2026-10-19): above `fittingSizeCompression`, which the toolbar sizes
    /// its items by (at 25 the field stayed at its 110 pt least in every window, measured), and below required, where it
    /// would fight SwiftUI's own bounds on the field and could hold the window wider than the reader drags it.
    @Test func theFieldsPreferredWidthSitsBetweenTheFittingSizeAndTheWindowsDrag() {
        #expect(ToolbarFieldWidth.priority > .fittingSizeCompression)
        #expect(ToolbarFieldWidth.priority < .dragThatCanResizeWindow)
    }

    /// **One watcher per window, kept by the window**: it follows the window's resizes whether the field is shown or
    /// in the overflow, a second arrival of the field reuses it, and closing the window frees it.
    @Test func eachWindowHasOneWatcherThatGoesWithIt() async throws {
        weak var freed: ToolbarFieldWidth?
        do {
            let window = Self.window(sidebar: false, subtitle: "")
            try await Self.resize(window, to: 900)
            let watcher = try #require(ToolbarFieldWidth.watcher(of: window))
            let field = try #require(window.toolbar?.items.compactMap(\.view).lazy
                .compactMap { Self.find(NSSearchField.self, in: $0) }.first)
            ToolbarFieldWidth.attach(field)
            #expect(ToolbarFieldWidth.watcher(of: window) === watcher, "a second arrival made a second watcher")
            freed = watcher
            window.close()
        }
        for _ in 0..<20 where freed != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(freed == nil, "the closed window's watcher outlived it")
    }

    /// **Every toolbar item has a name** (verifier, 2026-10-19: the Back/Forward pair, the text-size pair and the search
    /// field had none), for VoiceOver and the overflow menu, in the reader's language.
    /// **Who goes first, pinned on the live toolbar** (P8, P48; owner, 2026-10-19): the search field last (`.user`),
    /// then the speaker (`.high`), the two pairs first (`.low`).
    @Test func theSpeakerOutlastsThePairsAndTheFieldOutlastsAll() async throws {
        let window = Self.window(sidebar: false, subtitle: "")
        defer { window.close() }
        try await Self.resize(window, to: 1200)
        let priorities = (window.toolbar?.items ?? []).filter { $0.view != nil }.map { "\($0.label)=\($0.visibilityPriority.rawValue)" }
        let user = NSToolbarItem.VisibilityPriority.user.rawValue, high = NSToolbarItem.VisibilityPriority.high.rawValue
        let low = NSToolbarItem.VisibilityPriority.low.rawValue
        #expect(priorities == ["Back/Forward=\(low)", "Pronounce=\(high)", "Search=\(user)", "Text Size=\(low)"])
    }

    @Test func everyToolbarItemHasAName() async throws {
        let window = Self.window(sidebar: false, subtitle: "")
        defer { window.close() }
        try await Self.resize(window, to: 1200)
        let labels = (window.toolbar?.items ?? []).filter { $0.view != nil }.map(\.label)
        #expect(labels == ["Back/Forward", "Pronounce", "Search", "Text Size"])
        for key in ["Back/Forward", "Text Size", "Search"] {
            let chinese = try CompiledCatalog.text(LocalizedStringResource(stringLiteral: key), in: "zh-Hans")
            #expect(!chinese.isEmpty && chinese != key, "\(key) has no Chinese name: \(chinese)")
        }
    }
}

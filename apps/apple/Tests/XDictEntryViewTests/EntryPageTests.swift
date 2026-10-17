import AppKit
import Foundation
import Testing
import WebKit
@testable import XDictEntryView

/// **The All page** (Apple Dictionary parity P15, P16; ADR-0010 amendment of 2026-10-18): every dictionary's entry on
/// one page in the reader's order, each in a frame of its own with every confinement layer, Apple's collapsible divider
/// between them, the collapse kept per dictionary, frames made lazily, find stepping across them.
@MainActor
struct EntryPageTests {
    // MARK: - The plan

    @Test func onlyTheFirstSectionGoesWithoutADivider() {
        #expect(!EntryPagePlan.hasDivider(at: 0, collapsed: false))
        #expect(EntryPagePlan.hasDivider(at: 0, collapsed: true), "a collapsed first section could never be expanded")
        #expect(EntryPagePlan.hasDivider(at: 1, collapsed: false))
        #expect(EntryPagePlan.hasDivider(at: 5, collapsed: true))
    }

    /// 24 dictionaries at the estimated height in a 600 pt viewport: the frames on screen and one screen below, never
    /// all 24, and never a collapsed one.
    @Test func framesAreMadeForTheScreenAndOneBeyond() {
        let n = 24
        let heights = Array(repeating: EntryPagePlan.estimatedHeight, count: n)
        let tops = heights.indices.map { Double($0) * (EntryPagePlan.estimatedHeight + 32) }
        var collapsed = Array(repeating: false, count: n)
        collapsed[1] = true
        let wanted = EntryPagePlan.wanted(tops: tops, heights: heights, collapsed: collapsed, top: 0, height: 600)
        #expect(wanted == [0, 2, 3, 4])
        let lower = EntryPagePlan.wanted(tops: tops, heights: heights, collapsed: collapsed, top: 2_000, height: 600)
        #expect(lower.min() == 7 && lower.max() == 11)
    }

    /// The dividers follow the one text size (parity P15, P29): the name, the band and the triangle scale with it.
    @Test func dividersFollowTheTextSize() {
        let divider = EntryPageDivider(name: "Beta", zoom: 2)
        #expect(divider.label.font?.pointSize == 36)
        #expect(divider.fittingSize.height == 64)
        divider.setZoom(1)
        #expect(divider.label.font?.pointSize == 18)
        #expect(divider.fittingSize.height == 32)
        #expect(EntryPageDivider.metrics(zoom: 1.5) == .init(font: 27, height: 48, triangle: 8.25))
    }

    // MARK: - Print (P44)

    /// A page may end only between lines: the text's line boxes, merged where they overlap, leave the gaps it may end in.
    @Test func printBreaksFallBetweenLines() {
        #expect(EntryPrintPlan.breaks(lines: [(10, 30), (28, 50), (60, 80), (0, 5)]) == [5, 50, 80])
        #expect(EntryPrintPlan.breaks(lines: []) == [])
        // The largest break between the limit and the proposed bottom; none there, the proposed one.
        #expect(EntryPrintPlan.pageBottom(proposed: 75, limit: 40, breaks: [5, 50, 80]) == 50)
        #expect(EntryPrintPlan.pageBottom(proposed: 45, limit: 40, breaks: [5, 50, 80]) == 45)
    }

    /// Every expanded dictionary prints, in the page's order, each under its name; a collapsed one prints nothing.
    @Test func everyExpandedFramePrintsUnderItsName() {
        let plan = EntryPrintPlan.layout([("Alpha", 100, [40, 100]), ("Beta", 50, [50])], collapsed: [false, false])
        #expect(plan.map(\.name) == ["Alpha", "Beta"])
        #expect(plan.map(\.top) == [0, EntryPrintPlan.header + 100])
        #expect(plan.first?.breaks == [EntryPrintPlan.header + 40, EntryPrintPlan.header + 100])
        let one = EntryPrintPlan.layout([("Alpha", 100, []), ("Beta", 50, [])], collapsed: [true, false])
        #expect(one.map(\.name) == ["Beta"])
        #expect(one.first?.top == 0)
    }

    @Test func findStepsAcrossFramesAndWraps() {
        let counts = [2, 0, 3]
        var at = EntryPagePlan.step(from: nil, counts: counts, forward: true)
        #expect(at?.section == 0 && at?.match == 0)
        at = EntryPagePlan.step(from: (0, 1), counts: counts, forward: true)
        #expect(at?.section == 2 && at?.match == 0, "the empty section is passed over")
        at = EntryPagePlan.step(from: (2, 2), counts: counts, forward: true)
        #expect(at?.section == 0 && at?.match == 0, "wraps to the first")
        at = EntryPagePlan.step(from: (0, 0), counts: counts, forward: false)
        #expect(at?.section == 2 && at?.match == 2, "wraps back to the last")
        #expect(EntryPagePlan.step(from: nil, counts: [0, 0], forward: true) == nil)
        #expect(EntryPagePlan.position((2, 1), counts: counts) == 4)
        #expect(EntryPagePlan.position(nil, counts: counts) == 0)
    }

    // MARK: - The collapse, kept per dictionary

    @Test func collapseIsKeptPerDictionary() throws {
        let suite = "xdict.page.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EntryPreferences(defaults: defaults)
        #expect(!preferences.collapsed(for: "lineage-a"))
        preferences.setCollapsed(true, for: "lineage-a")
        #expect(preferences.collapsed(for: "lineage-a"))
        #expect(!preferences.collapsed(for: "lineage-b"))
        #expect(EntryPreferences(defaults: defaults).collapsed(for: "lineage-a"), "kept across launches")
        preferences.setCollapsed(false, for: "lineage-a")
        #expect(!preferences.collapsed(for: "lineage-a"))
    }

    // MARK: - The page

    private func page(_ names: [String], collapsed: Set<String> = [], ruleList: Bool = true)
        async throws -> (EntryViewController, [FakeContent], UserDefaults, String) {
        let suite = "xdict.page.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preferences = EntryPreferences(defaults: defaults)
        for name in collapsed { preferences.setCollapsed(true, for: "lineage-\(name)") }
        var environment = EntryEnvironment(preferences: preferences)
        environment.ruleListDirectory = FileManager.default.temporaryDirectory
            .appending(path: "xdict-page-rules-\(UUID().uuidString)")
        if !ruleList {
            // WebKit's switches cannot be read: the gate refuses (`EntryPane.gate`).
            environment.switches = { _ in
                let switches = FakeSwitches()
                switches.listed = nil
                return switches
            }
        }
        let controller = EntryViewController(environment: environment)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let contents = names.map { name in
            let content = FakeContent(name)
            content.documents[name] = EntryDocument(html: Data("<b>\(name)</b>".utf8), policy: "default-src 'none'")
            return content
        }
        let items = zip(names, contents).map { name, content in
            EntryPageItem(id: UUID(), name: name.capitalized, content: content, reference: EntryReference(key: name))
        }
        _ = await controller.showPage(items, primary: items.first?.id)
        return (controller, contents, defaults, suite)
    }

    /// Reader's order, one section each, the first with no divider, each divider named by its dictionary.
    @Test func sectionsFollowTheReadersOrderWithApplesDividers() async throws {
        let (controller, _, defaults, suite) = try await page(["alpha", "beta", "gamma"])
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        let sections = try #require(controller.pageSections)
        #expect(sections.map(\.name) == ["Alpha", "Beta", "Gamma"])
        #expect(sections.map(\.hasDivider) == [false, true, true])
        #expect(sections.dropFirst().allSatisfy { $0.divider.accessibilityLabel() == $0.name })
        #expect(sections.allSatisfy { !$0.collapsed })
    }

    /// **Every frame is a pane of its own, with every layer** (ADR-0007 decision 14, ADR-0009 decision 7): its own
    /// non-persistent data store, its own scheme handler answering from its own dictionary alone, the rule list, the
    /// switches read back off. No two frames share a store, a handler or a web view.
    @Test func everyFrameIsIsolatedWithEveryLayer() async throws {
        let (controller, contents, defaults, suite) = try await page(["alpha", "beta", "gamma"])
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        let panes = try #require(controller.pagePanes)
        #expect(panes.count == 3)
        #expect(panes.map(\.binding) == contents.map(\.binding))
        let stores = panes.map { ObjectIdentifier($0.view.configuration.websiteDataStore) }
        #expect(Set(stores).count == 3, "two frames share a data store")
        #expect(panes.allSatisfy { !$0.view.configuration.websiteDataStore.isPersistent })
        let handlers = panes.compactMap { $0.view.configuration.urlSchemeHandler(forURLScheme: EntryRoutes.scheme) }
            .map { ObjectIdentifier($0) }
        #expect(handlers.count == 3 && Set(handlers).count == 3, "two frames share a scheme handler")
        #expect(Set(panes.map { ObjectIdentifier($0.view) }).count == 3)
        #expect(Set(panes.map { ObjectIdentifier($0.view.configuration.userContentController) }).count == 3)
        #expect(panes.allSatisfy { !$0.switchesReadBack.isEmpty && $0.switchesReadBack.values.allSatisfy { !$0 } })
        #expect(panes.allSatisfy { !$0.view.configuration.preferences.javaScriptCanOpenWindowsAutomatically })
    }

    /// A layer that cannot be put in place refuses the whole page: no frame is made for any dictionary.
    @Test func aLayerThatCannotHoldRefusesEveryFrame() async throws {
        let (controller, _, defaults, suite) = try await page(["alpha", "beta"], ruleList: false)
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(controller.refusal != nil)
        #expect(controller.pagePanes?.isEmpty ?? true)
        #expect(controller.webView == nil)
    }

    /// A collapsed dictionary keeps its divider, makes no frame, and the reader's click expands it and is kept.
    @Test func collapsingADictionaryIsKeptAndExpandingMakesItsFrame() async throws {
        let (controller, _, defaults, suite) = try await page(["alpha", "beta", "gamma"], collapsed: ["beta"])
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        var sections = try #require(controller.pageSections)
        #expect(sections.map(\.collapsed) == [false, true, false])
        #expect(sections[1].pane == nil, "a collapsed frame was made")
        sections[1].divider.toggle()
        sections = try #require(controller.pageSections)
        #expect(!sections[1].collapsed)
        #expect(sections[1].pane != nil)
        #expect(!EntryPreferences(defaults: defaults).collapsed(for: "lineage-beta"))
        sections[2].divider.toggle()
        #expect(EntryPreferences(defaults: defaults).collapsed(for: "lineage-gamma"))
    }

    /// Showing the page again as another dictionary answers keeps the frames already there, and adds the new one in
    /// its place in the reader's order.
    @Test func showingThePageAgainKeepsItsFrames() async throws {
        let (controller, contents, defaults, suite) = try await page(["alpha", "gamma"])
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        let before = try #require(controller.pagePanes)
        let beta = FakeContent("beta")
        beta.documents["beta"] = EntryDocument(html: Data("<b>beta</b>".utf8), policy: "default-src 'none'")
        let ids = try #require(controller.pageSections).map(\.id)
        let items = [
            EntryPageItem(id: ids[0], name: "Alpha", content: contents[0], reference: EntryReference(key: "alpha")),
            EntryPageItem(id: UUID(), name: "Beta", content: beta, reference: EntryReference(key: "beta")),
            EntryPageItem(id: ids[1], name: "Gamma", content: contents[1], reference: EntryReference(key: "gamma")),
        ]
        _ = await controller.showPage(items, primary: ids[0])
        let after = try #require(controller.pagePanes)
        #expect(try #require(controller.pageSections).map(\.name) == ["Alpha", "Beta", "Gamma"])
        #expect(after.first === before.first && after.last === before.last)
        #expect(after.count == 3)
    }

    /// One dictionary's page, or a single entry, leaves page mode: the single pane is back, the page gone.
    @Test func aSingleEntryReplacesThePage() async throws {
        let (controller, contents, defaults, suite) = try await page(["alpha", "beta"])
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        _ = await controller.show(EntryReference(key: "alpha"), from: contents[0])
        #expect(controller.pageSections == nil)
        #expect(controller.webView != nil)
    }
}

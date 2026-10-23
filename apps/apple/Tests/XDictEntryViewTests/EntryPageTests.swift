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

    /// **Tab from the results reaches the page** (lookup E2E, 2026-10-18: Tab went back to the search field): the frame
    /// Tab lands in is the first expanded, made frame still on screen at the page's scroll position; else the first
    /// expanded, made frame; none when no frame is made.
    @Test func tabLandsInTheFirstFrameOnScreen() {
        let tops: [Double] = [0, 300, 600, 900]
        let heights: [Double] = [300, 300, 300, 300]
        let open = [false, false, false, false]
        #expect(EntryPagePlan.firstKeyFrame(tops: tops, heights: heights, collapsed: open,
                                            made: [true, true, true, false], top: 0) == 0)
        #expect(EntryPagePlan.firstKeyFrame(tops: tops, heights: heights, collapsed: [true, false, false, false],
                                            made: [true, true, true, false], top: 0) == 1, "a collapsed frame is hidden")
        #expect(EntryPagePlan.firstKeyFrame(tops: tops, heights: heights, collapsed: open,
                                            made: [false, true, true, false], top: 0) == 1, "an unmade frame has no view")
        #expect(EntryPagePlan.firstKeyFrame(tops: tops, heights: heights, collapsed: open,
                                            made: [true, true, true, false], top: 650) == 2, "scrolled past 0 and 1")
        #expect(EntryPagePlan.firstKeyFrame(tops: tops, heights: heights, collapsed: open,
                                            made: [true, true, false, false], top: 950) == 0,
                "nothing made on screen: the first made frame")
        #expect(EntryPagePlan.firstKeyFrame(tops: tops, heights: heights, collapsed: open,
                                            made: [false, false, false, false], top: 0) == nil)
    }

    @Test func onlyTheFirstSectionGoesWithoutADivider() {
        #expect(!EntryPagePlan.hasDivider(at: 0, collapsed: false))
        #expect(EntryPagePlan.hasDivider(at: 0, collapsed: true), "a collapsed first section could never be expanded")
        #expect(EntryPagePlan.hasDivider(at: 1, collapsed: false))
        #expect(EntryPagePlan.hasDivider(at: 5, collapsed: true))
        #expect(EntryPagePlan.hasDivider(at: 0, collapsed: false, style: .popover), "the popover names every section")
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
    /// **Quieter than the headword** (HIG audit UI25): the name is the dictionary-name role (13 pt semibold at actual
    /// size), not Apple's 18 pt.
    @Test func dividersFollowTheTextSize() {
        let divider = EntryPageDivider(name: "Beta", zoom: 2)
        #expect(divider.label.font?.pointSize == 26)
        #expect(divider.fittingSize.height == 64)
        divider.setZoom(1)
        #expect(divider.label.font?.pointSize == 13)
        #expect(divider.fittingSize.height == 32)
        #expect(EntryPageDivider.metrics(zoom: 1.5) == .init(font: 19.5, height: 48, triangle: 8.25))
    }

    /// **A quiet source header with a clear disclosure control** (HIG audit UI25): the name leads, just after the
    /// triangle, in the secondary label colour and the dictionary-name role's weight; the rule runs only after it, in
    /// the system's separator colour; it stays a disclosure triangle VoiceOver can press, and with full keyboard access
    /// Space or Return toggles it as a button's would.
    @Test func theDividerIsAQuietLeadingHeader() throws {
        let divider = EntryPageDivider(name: "Beta", zoom: 1)
        #expect(divider.label.alignment == .natural)
        #expect(divider.label.textColor == .secondaryLabelColor)
        let weight = try #require(divider.label.font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])
        #expect((weight[.weight] as? CGFloat ?? 0) >= NSFont.Weight.semibold.rawValue - 0.01)
        #expect(EntryPageDivider.ruleColour == .separatorColor)
        divider.frame = NSRect(x: 0, y: 0, width: 500, height: 32)
        divider.layoutSubtreeIfNeeded()
        // Layout places a label's alignment rectangle (where its text starts); its frame reaches 2 pt further out.
        #expect(divider.label.alignmentRect(forFrame: divider.label.frame).minX == EntryPageDivider.ruleStart,
                "the name leads, after the triangle")
        #expect(divider.accessibilityRole() == .disclosureTriangle)
        var toggles = 0
        divider.onToggle = { toggles += 1 }
        #expect(divider.accessibilityPerformPress())
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: " ",
                                                  charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        divider.keyDown(with: space)
        #expect(toggles == 2, "Space did not toggle the divider")
    }

    // MARK: - Evidence and orientation (HIG audit UI11, UI24)

    /// **The pinned name is a label, not a control** (UI24): hidden until a name is pinned, read by VoiceOver as the
    /// current dictionary, and every click passes to the page under it.
    @Test func thePinnedNameIsQuietAndNotAControl() {
        let label = EntryPageSourceLabel()
        #expect(label.isHidden)
        label.show("Beta")
        #expect(!label.isHidden && label.label.stringValue == "Beta")
        #expect(label.accessibilityLabel()?.contains("Beta") == true)
        #expect(label.accessibilityRole() == .staticText)
        #expect(label.hitTest(.zero) == nil)
        label.show(nil)
        #expect(label.isHidden)
    }

    /// **Evidence is shown only in the frame it names** (UI11): the frozen target's handle, edition and reference must
    /// name exactly one frame. Another edition, another occurrence, or two frames claiming the same name reveal nothing.
    @Test func evidenceIsRevealedOnlyInTheFrameItNames() {
        let alpha = EntryFrameName(handle: "h-a", edition: "e1", reference: EntryReference(key: "run"))
        let beta = EntryFrameName(handle: "h-b", edition: "e1", reference: EntryReference(key: "run"))
        #expect(EntryPagePlan.frame(named: beta, among: [alpha, beta]) == 1)
        #expect(EntryPagePlan.frame(named: alpha, among: [alpha, beta]) == 0)
        #expect(EntryPagePlan.frame(named: EntryFrameName(handle: "h-b", edition: "e2", reference: EntryReference(key: "run")),
                                    among: [alpha, beta]) == nil, "another edition")
        #expect(EntryPagePlan.frame(named: EntryFrameName(handle: "h-b", edition: "e1",
                                                          reference: EntryReference(key: "run", occurrence: 1)),
                                    among: [alpha, beta]) == nil, "another occurrence")
        #expect(EntryPagePlan.frame(named: beta, among: [beta, beta]) == nil, "an ambiguous name")
        #expect(EntryPagePlan.frame(named: beta, among: []) == nil)
    }

    /// **The dictionary being read** (UI24): the last section whose start (its divider, or the first frame's top) is at
    /// or above the view's top; its name is pinned once its own header has scrolled away, on the window's page of more
    /// than one dictionary only.
    @Test func theCurrentSourceFollowsTheScroll() {
        let starts: [Double] = [0, 300, 900]
        #expect(EntryPagePlan.current(starts: starts, top: 0) == 0)
        #expect(EntryPagePlan.current(starts: starts, top: 299) == 0)
        #expect(EntryPagePlan.current(starts: starts, top: 300) == 1)
        #expect(EntryPagePlan.current(starts: starts, top: 5_000) == 2)
        #expect(EntryPagePlan.current(starts: [], top: 0) == nil)
        #expect(!EntryPagePlan.pinsSource(current: 0, starts: starts, top: 0, style: .window), "the page's top")
        #expect(EntryPagePlan.pinsSource(current: 0, starts: starts, top: 40, style: .window))
        #expect(!EntryPagePlan.pinsSource(current: 1, starts: starts, top: 300, style: .window), "its divider shows")
        #expect(EntryPagePlan.pinsSource(current: 1, starts: starts, top: 340, style: .window))
        #expect(!EntryPagePlan.pinsSource(current: 1, starts: starts, top: 340, style: .popover))
        #expect(!EntryPagePlan.pinsSource(current: 0, starts: [0], top: 40, style: .window), "one dictionary")
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

    private func page(_ names: [String], collapsed: Set<String> = [], ruleList: Bool = true, popover: Bool = false)
        async throws -> (EntryViewController, [FakeContent], UserDefaults, String) {
        let suite = "xdict.page.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preferences = EntryPreferences(defaults: defaults)
        for name in collapsed { preferences.setCollapsed(true, for: "lineage-\(name)") }
        var environment = EntryEnvironment(preferences: preferences)
        if popover { environment.readingFrame = environment.readingFrame.union(.panel) }
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

    // MARK: - The lookup popover's stack (P41, owner 2026-10-18)

    /// **The popover stacks every dictionary as Apple's does** (popover.dark.png): every section, the first included,
    /// under its name (the title row is the headword), in the reader's order, each its own isolated frame.
    @Test func thePopoverStacksEveryDictionaryUnderItsName() async throws {
        let (controller, contents, defaults, suite) = try await page(["alpha", "beta", "gamma"], popover: true)
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        let sections = try #require(controller.pageSections)
        #expect(sections.map(\.name) == ["Alpha", "Beta", "Gamma"])
        #expect(sections.map(\.hasDivider) == [true, true, true], "the popover names its first dictionary too")
        #expect(sections.allSatisfy { $0.divider.style == .popover })
        let panes = try #require(controller.pagePanes)
        #expect(panes.map(\.binding) == contents.map(\.binding))
        #expect(Set(panes.map { ObjectIdentifier($0.view.configuration.websiteDataStore) }).count == 3)
    }

    /// Apple's popover sections have no triangle and do not collapse: a dictionary collapsed in the main window is
    /// still shown in the popover, which has no way to expand it, and the main window's choice is kept.
    @Test func thePopoverNeitherCollapsesNorDrawsATriangle() async throws {
        let (controller, _, defaults, suite) = try await page(["alpha", "beta"], collapsed: ["beta"], popover: true)
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        let sections = try #require(controller.pageSections)
        #expect(sections.map(\.collapsed) == [false, false])
        #expect(sections[1].pane != nil)
        sections[1].divider.toggle()
        #expect(!sections[1].collapsed, "a popover divider toggled")
        #expect(EntryPreferences(defaults: defaults).collapsed(for: "lineage-beta"), "the main window's choice kept")
    }

    /// **Apple's compact divider** (popover.png, popover.dark.png): the name leading at the title's 24 pt inset, in the
    /// system font at 13 pt semibold (owner, 2026-10-18: smaller than Apple's 20) and the secondary label colour, then a hairline to 27 pt from the trailing edge; a 40 pt band (an
    /// 8 pt gap each side of the 24 pt row), not following the text size, as the title row does not.
    @Test func thePopoverDividerIsApplesCompactOne() {
        let divider = EntryPageDivider(name: "LDOC", zoom: 2, style: .popover)
        #expect(divider.label.font?.pointSize == 13)
        #expect(divider.label.textColor == .secondaryLabelColor)
        #expect(divider.label.alignment == .natural)
        #expect(divider.fittingSize.height == 40)
        #expect(divider.accessibilityRole() == .staticText, "nothing to press")
        #expect(EntryPageDivider.Popover.leading == 24 && EntryPageDivider.Popover.trailing == 27)
        divider.setZoom(1)
        #expect(divider.label.font?.pointSize == 13)
        let window = EntryPageDivider(name: "LDOC", zoom: 1)
        #expect(window.style == .window && window.label.font?.pointSize == 13)
    }

    /// **The page's height** (the popover sizes to its stack): every shown divider's band and every expanded frame,
    /// told whenever a frame's height changes; the popover's page draws nothing of its own under the glass.
    @Test func thePageReportsItsHeightAsItsFramesGrow() async throws {
        let (controller, _, defaults, suite) = try await page(["alpha", "beta"], popover: true)
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        let sections = try #require(controller.pageSections)
        // Synchronous from here to the last check: a frame's own load cannot move a height in between.
        var told = 0
        controller.onContentHeightChanged = { told += 1 }
        sections[0].setHeight(100_001)
        sections[1].setHeight(50_001)
        let expected = 2 * Double(EntryPageDivider.Popover.height) + 150_002
        #expect(controller.pageHeight == expected)
        #expect(told == 2)
        sections[1].setHeight(50_001)
        #expect(told == 2, "an unchanged height is not news")
        #expect(controller.pageDrawsBackground == false)
        let measured = try #require(await controller.documentHeight())
        #expect(measured == controller.pageHeight, "the popover measures the page, not one frame")
    }

    @Test func theWindowsPageKeepsItsPaper() async throws {
        let (controller, _, defaults, suite) = try await page(["alpha"])
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(controller.pageDrawsBackground == true)
    }

    /// **Show in the Entry reveals only in the frame the answer quoted** (UI11): a target naming no frame shown (here,
    /// another edition) opens nothing and reports false; the named frame, collapsed, is opened for the reveal, while the
    /// reader's kept collapse for that dictionary is left as it was.
    @Test func revealingEvidenceOpensOnlyItsOwnFrame() async throws {
        let (controller, contents, defaults, suite) = try await page(["alpha", "beta", "gamma"], collapsed: ["beta", "gamma"])
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        let beta = contents[1].binding
        let wrong = EntryFrameName(handle: beta.handle, edition: "another", reference: EntryReference(key: "beta"))
        #expect(await controller.revealEvidence("Beta", in: wrong).value == false)
        var sections = try #require(controller.pageSections)
        #expect(sections.map(\.collapsed) == [false, true, true], "a reveal with no frame opened one")
        let named = EntryFrameName(handle: beta.handle, edition: beta.edition, reference: EntryReference(key: "beta"))
        _ = await controller.revealEvidence("Beta", in: named).value
        sections = try #require(controller.pageSections)
        #expect(sections.map(\.collapsed) == [false, false, true])
        #expect(sections[1].pane != nil, "the named frame was not made")
        #expect(EntryPreferences(defaults: defaults).collapsed(for: "lineage-beta"), "the reader's collapse was overwritten")
    }

    /// **The page names its dictionaries and the one being read** (UI24): what the window's jump list and pinned name
    /// show; none for a single entry.
    @Test func thePageNamesItsSourcesAndTheCurrentOne() async throws {
        let (controller, _, defaults, suite) = try await page(["alpha", "beta"])
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        let sources = try #require(controller.pageSources)
        let sections = try #require(controller.pageSections)
        #expect(sources.sources.map(\.name) == ["Alpha", "Beta"])
        #expect(sources.sources.map(\.id) == sections.map(\.id))
        #expect(sources.current == sections[0].id)
        #expect(!sources.pinned)
        var told: [EntryPageSources?] = []
        controller.onPageSourcesChanged = { told.append($0) }
        controller.closeEntry()
        #expect(controller.pageSources == nil)
        #expect(told.last == .some(nil), "closing the page did not clear its sources")
    }
}

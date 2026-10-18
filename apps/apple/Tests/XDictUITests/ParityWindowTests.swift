import AppKit
import Foundation
import SwiftUI
import Testing
import XDictLibrary
import XDictSearch
import XDictTestSupport
@testable import XDictUI

/// **The main window as Apple's Dictionary has it** (parity ledger groups A, B, E; owner's decisions of 2026-10-17):
/// each a decision a view makes, without a window. What only a window shows — the toolbar's order, the scope bar's
/// radio group, the sidebar's table, the menu bar's keys — the UI tour's parity checks hold (`Tools/ui-tour/parity.py`).
@MainActor
struct ParityWindowTests {
    static func text(_ resource: LocalizedStringResource?) -> String {
        resource.map { (try? CompiledCatalog.text($0, in: "en")) ?? "the catalog did not compile" } ?? ""
    }

    static func chinese(_ resource: LocalizedStringResource) -> String {
        (try? CompiledCatalog.text(resource, in: "zh-Hans")) ?? "the catalog did not compile"
    }

    /// **P1**: Apple's 400 × 300 pt minimum, which replaces the 640 × 420 pt one.
    @Test func theWindowsMinimumIsApplesFourHundredByThreeHundred() {
        #expect(ToolbarLayout.minimumWindow == (width: 400, height: 300))
        // Apple's search field is 327 pt at an 859 pt window (P5).
        #expect(ToolbarLayout.searchWidth.ideal == 327)
        // Apple's sidebar is 183 pt at an 859 pt window (P9).
        #expect(ToolbarLayout.sidebar.ideal == 183)
        // P8: at the 400 pt minimum the title yields to the search field; at Apple's 859 pt it shows.
        // P8: the search field's toolbar item outlasts every other.
        #expect(ToolbarPriority.priority(holdsSearch: true) == .user)
        #expect(ToolbarPriority.priority(holdsSearch: false) == .low)
        #expect(ToolbarLayout.titleYields(width: 400) && !ToolbarLayout.titleYields(width: 859))
    }

    /// **P8**: when the content column is under 560 pt the title and its count give way, as Apple's slide under the
    /// search field; wider, they show. The column is the window less the sidebar: a search's sidebar widened a 400 pt
    /// window to 583 pt and the title came back over a 400 pt column (UI tour `main.narrow`, 2026-10-18).
    @Test func narrowTheTitleAndItsCountGiveWay() {
        #expect(ToolbarLayout.titleYields(window: 583, sidebar: 183))
        #expect(ToolbarLayout.titleYields(window: 444, sidebar: 183), "Apple's narrow window")
        #expect(!ToolbarLayout.titleYields(window: 859, sidebar: 183))
        #expect(!ToolbarLayout.titleYields(window: 640, sidebar: 0))
    }

    /// **P2**: the title is "Dictionary" always; "N found" under it counts the list, in the reader's grammar, and is
    /// absent for no result and for spelling guesses.
    @Test func theTitleIsDictionaryWithTheCountUnderIt() {
        #expect(Self.text(ToolbarLayout.windowTitle) == "Dictionary")
        #expect(Self.chinese(ToolbarLayout.windowTitle) == "词典")
        #expect(Self.text(ToolbarLayout.subtitle(found: 45)) == "45 found")
        #expect(Self.text(ToolbarLayout.subtitle(found: 1)) == "1 found")
        #expect(ToolbarLayout.subtitle(found: nil) == nil)
    }

    /// **P6, P8**: every scope when they fit; else as many as fit beside the » button, "All" always.
    @Test func theScopeBarShowsWhatFitsAndOverflowsTheRest() {
        let widths: [CGFloat] = [36, 86, 56, 117]
        #expect(ScopeBarLayout.shown(widths: widths, available: 400) == 4)
        #expect(ScopeBarLayout.shown(widths: widths, available: 7 + 36 + 86 + 56 + 36) == 3)
        #expect(ScopeBarLayout.shown(widths: widths, available: 7 + 36 + 86 + 36 + 10) == 2)
        #expect(ScopeBarLayout.shown(widths: widths, available: 20) == 1, "All always shows")
        #expect(ScopeBarLayout.height == 36 && ScopeBarLayout.buttonHeight == 22)
        let sources = [SearchSource(id: UUID(), name: "Alpha", edition: nil, preferencesKey: "a", enabled: true,
                                    state: .indexing(fraction: nil)),
                       SearchSource(id: UUID(), name: "Off", edition: nil, preferencesKey: "o", enabled: false,
                                    state: .indexing(fraction: nil))]
        #expect(ScopeBarLayout.scopes(sources) == [.all, .one(sources[0].id)])
    }

    /// **P7**: ⌘0 every dictionary, ⌘1–⌘9 the first nine, ⌘} and ⌘{ to step; Actual Size moved to ⌥⌘0.
    @Test func theSearchMenuHasApplesKeys() {
        #expect(ScopeShortcut.all == "0")
        #expect(ScopeShortcut.dictionary(0) == "1")
        #expect(ScopeShortcut.dictionary(8) == "9")
        #expect(ScopeShortcut.dictionary(9) == nil)
        #expect(ScopeShortcut.next == "}" && ScopeShortcut.previous == "{")
        #expect(ScopeShortcut.actualSize == "0")
    }

    /// **P12, P14**: before a search, the start page; nothing found, Apple's plain line; a list about to show a row,
    /// nothing at all (no flash of "No entries found.").
    @Test func thePlaceholdersAreApplesStartPageAndPlainLine() {
        #expect(EntryPlaceholder.of(noDictionaries: false, query: nil, selection: nil, searching: false) == .start)
        #expect(EntryPlaceholder.of(noDictionaries: false, query: "zz", selection: nil, searching: false) == .noResults("zz"))
        #expect(EntryPlaceholder.of(noDictionaries: false, query: "take o", selection: nil, searching: false,
                                    pending: true) == .searching)
        #expect(Self.text(LocalizedStringResource("No entries found.")) == "No entries found.")
        #expect(Self.text(LocalizedStringResource("Type a word to look up in…")) == "Type a word to look up in…")
        #expect(Self.text(LocalizedStringResource("Did you mean?")) == "Did you mean?")
        #expect(Self.text(LocalizedStringResource("Search")) == "Search")
    }

    /// **Tab from the results reaches the entry** (lookup E2E, 2026-10-18: it went back to the search field): the list's
    /// next key view is whatever the entry names when Tab is pressed, whatever the window's key-view loop says.
    @Test func tabFromTheResultsReachesTheEntry() throws {
        final class Entry: NSView { override var acceptsFirstResponder: Bool { true } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let field = NSTextField(frame: NSRect(x: 0, y: 270, width: 200, height: 22))
        let table = HeadwordTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 260))
        let entry = Entry(frame: NSRect(x: 110, y: 0, width: 290, height: 260))
        let content = try #require(window.contentView)
        [field, table, entry].forEach(content.addSubview)
        table.nextKeyView = field
        #expect(table.nextValidKeyView === field, "without an entry, the window's loop")
        table.entryKeyView = { entry }
        #expect(table.nextValidKeyView === entry)
        entry.isHidden = true
        #expect(table.nextValidKeyView === field, "a hidden entry cannot take the keyboard")
    }

    /// **P6, P42**: the scope bar reads as one radio group named "Dictionaries", each scope a `scope.option` named by its
    /// title, the chosen one's value 1 and every other's 0 — what VoiceOver and the lookup driver read the choice by.
    @Test func theScopeBarNamesItsGroupAndItsChoice() throws {
        let bar = ScopeBarView(frame: NSRect(x: 0, y: 0, width: 600, height: ScopeBarLayout.height))
        let beta = UUID()
        bar.update(items: [ScopeBarView.Item(scope: .all, title: "All", enabled: true),
                           ScopeBarView.Item(scope: .one(UUID()), title: "Alpha", enabled: true),
                           ScopeBarView.Item(scope: .one(beta), title: "Beta", enabled: true)],
                   selected: .one(beta))
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let group = try #require(descendants(bar).compactMap { $0 as? ScopeRadioGroup }.first)
        #expect(group.accessibilityIdentifier() == "scope")
        #expect(group.accessibilityLabel() == String(localized: "Dictionaries"))
        let options = descendants(bar).compactMap { $0 as? ScopeButton }
        #expect(options.map { $0.accessibilityIdentifier() } == ["scope.option", "scope.option", "scope.option"])
        #expect(options.map { $0.accessibilityLabel() } == ["All", "Alpha", "Beta"])
        #expect(options.map { ($0.accessibilityValue() as? NSNumber)?.intValue } == [0, 0, 1])
    }
}

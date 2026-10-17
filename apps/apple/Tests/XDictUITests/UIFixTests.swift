import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
import XDictAnywhere
import XDictContract
import XDictLibrary
import XDictSearch
import XDictTestSupport
import XDictUI

/// **The UI review's behaviour fixes** (plan-macos-v1 WI-13, the fix round of 2026-10-17): each the decision a view
/// makes, without a window (the build Mac opens none). Layout is checked by the tour's re-capture, not here.
struct UIFixTests {
    /// In English, through the compiled catalog, so plural forms are chosen as the reader sees them.
    static func text(_ resource: LocalizedStringResource?) -> String {
        resource.map { (try? CompiledCatalog.text($0, in: "en")) ?? "the catalog did not compile" } ?? ""
    }

    // MARK: - X1: a placeholder covers, and clears, the previous entry

    /// After a lookup with no hit, the last entry stayed under "No Results" and VoiceOver could still reach it. Every
    /// placeholder now says the entry behind it goes; only "nothing to cover" keeps it.
    @Test func everyPlaceholderClearsTheEntryBehindIt() {
        let id = ResultID(dictionary: UUID(), entry: EntryRef(edition: Edition(rawValue: "mdx-sha256-v1:00"), key: "apple", occurrence: 0))
        let none = EntryPlaceholder.of(noDictionaries: false, query: "zzqxjv", selection: nil, searching: false)
        #expect(none == .noResults("zzqxjv"))
        #expect(none.clearsEntry)
        #expect(EntryPlaceholder.of(noDictionaries: true, query: nil, selection: nil, searching: false) == .noDictionaries)
        #expect(EntryPlaceholder.of(noDictionaries: false, query: nil, selection: nil, searching: false).clearsEntry)
        let shown = EntryPlaceholder.of(noDictionaries: false, query: "apple", selection: id, searching: false)
        #expect(shown == .none)
        #expect(!shown.clearsEntry)
        #expect(EntryPlaceholder.of(noDictionaries: false, query: "a", selection: nil, searching: true) == .searching)
    }

    // MARK: - X3: one problem status, the full sentence

    /// A dictionary that cannot be used says why in full wherever it is named; one that can says nothing.
    @Test func aTroubledDictionaryHasItsWholeSentenceAndAReadyOneNone() {
        let damaged = ProblemStatus.sentence(for: .refused(.damaged))
        #expect(!Self.text(damaged).isEmpty)
        #expect(Self.text(damaged) == Self.text(LibrarySentences.phase(.refused(.damaged))))
        #expect(!Self.text(ProblemStatus.sentence(for: .missing(fileName: "gone.mdx"))).isEmpty)
        #expect(ProblemStatus.sentence(for: .ready) == nil)
        #expect(ProblemStatus.sentence(for: .importing(done: 1, total: 2)) == nil)
        #expect(ProblemStatus.sentence(for: nil) == nil)
    }

    // MARK: - L-04: the action each problem needs

    @Test func eachProblemOffersTheActionThatCanFixIt() {
        #expect(LibraryRowAction.for(.missing(fileName: "gone.mdx")) == .locate)
        #expect(LibraryRowAction.for(.outsideItsFolder(fileName: "x.mdx")) == .locate)
        #expect(LibraryRowAction.for(.refused(.damaged)) == .showInFinder)
        #expect(LibraryRowAction.for(.refused(.registrationCode)) == .showInFinder)
        #expect(LibraryRowAction.for(.failed(.serviceFailed)) == .tryAgain)
        #expect(LibraryRowAction.for(.cancelled) == .tryAgain)
        #expect(LibraryRowAction.for(.importing(done: 0, total: 1)) == .cancel)
        #expect(LibraryRowAction.for(.ready) == nil)
    }

    // MARK: - X7: notices coalesced, each with its reason

    @Test func severalNoticesAreOneLineAndAFileThatCouldNotBeReadSaysWhy() {
        #expect(Self.text(LibrarySentences.noticesHeadline(1)) == "1 file could not be added.")
        #expect(Self.text(LibrarySentences.noticesHeadline(6)) == "6 files could not be added.")
        let unreadable = Self.text(LibrarySentences.notice(.finder(.unreadable(fileName: "x.mdx"))))
        #expect(unreadable.contains("x.mdx"))
        #expect(unreadable.contains("moved") || unreadable.contains("permission"), "no reason: \(unreadable)")
    }

    // MARK: - X8: counts in the reader's grammar

    @Test func oneEntryIsNotAllOneEntries() {
        let one = Self.text(LibrarySentences.healthStatus(.checked(Health(version: 1, entries: 1, findings: [], classes: []))))
        #expect(!one.contains("all 1 entries"), "\(one)")
        #expect(one.contains("1 entry"), "\(one)")
    }

    // MARK: - A-07, S-06: the shortcut as a menu shows it and as VoiceOver says it

    @Test func theShortcutIsAKeyEquivalentAndASpokenName() {
        let shortcut = Shortcut.defaultLookUp
        let equivalent = ShortcutDisplay.keyEquivalent(shortcut, keyName: { _ in "d" })
        #expect(equivalent?.key == "d")
        #expect(equivalent?.modifiers == [.control, .option])
        #expect(ShortcutDisplay.spoken(shortcut, keyName: { _ in "d" }) == "Control-Option-D")
        #expect(ShortcutDisplay.keyEquivalent(Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey)),
                                              keyName: { _ in nil }) == nil)
    }

    // MARK: - Dark captures: an instrument's argument, refused in a reader's launch

    @Test func theAppearanceArgumentIsAnInstrumentsAlone() {
        #expect(InstrumentAppearance.parse(["--lookup-window", "/w", "--appearance", "dark"]) == .success(.dark))
        #expect(InstrumentAppearance.parse(["--lookup-window", "/w", "--appearance", "light"]) == .success(.light))
        #expect(InstrumentAppearance.parse(["--lookup-window", "/w"]) == .success(nil))
        #expect(InstrumentAppearance.parse([]) == .success(nil))
        #expect(InstrumentAppearance.parse(["--appearance", "dark"]) == .failure(.notAnInstrument))
        #expect(InstrumentAppearance.parse(["--lookup-window", "/w", "--appearance", "sepia"])
                == .failure(.unknown("sepia")))
        #expect(InstrumentAppearance.parse(["--lookup-window", "/w", "--appearance"]) == .failure(.unknown("")))
    }

    // P-01 (the panel showed only its close button) gave way to P41: no window buttons, PopoverParityTests.
}

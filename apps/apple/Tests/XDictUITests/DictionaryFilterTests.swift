import Foundation
import Testing
import XDictContract
import XDictLibrary
@testable import XDictUI

/// **Settings ▸ Dictionaries' row status and filter** (UI34, UI35): each row says whether it is ready, off, under way or
/// in trouble in words and a symbol, never colour alone; the filter keeps the library's order, never hides a row that
/// needs the reader, and never drops the selected row.
struct DictionaryFilterTests {
    static let ids = (0..<5).map { _ in UUID() }

    @Test func eachRowSaysItsStatus() {
        #expect(DictionaryRowStatus.of(enabled: true, phase: .ready) == .ready)
        #expect(DictionaryRowStatus.of(enabled: true, phase: nil) == .ready)
        #expect(DictionaryRowStatus.of(enabled: false, phase: .ready) == .off)
        #expect(DictionaryRowStatus.of(enabled: true, phase: .waiting) == .importing)
        #expect(DictionaryRowStatus.of(enabled: true, phase: .importing(done: 1, total: 2)) == .importing)
        #expect(DictionaryRowStatus.of(enabled: true, phase: .opening) == .importing)
        #expect(DictionaryRowStatus.of(enabled: true, phase: .cancelling) == .importing)
        #expect(DictionaryRowStatus.of(enabled: true, phase: .cancelled) == .cancelled)
        #expect(DictionaryRowStatus.of(enabled: false, phase: .missing(fileName: "a.mdx")) == .missing)
        #expect(DictionaryRowStatus.of(enabled: true, phase: .outsideItsFolder(fileName: "a.mdx")) == .missing)
        #expect(DictionaryRowStatus.of(enabled: true, phase: .refused(.damaged)) == .damaged)
        #expect(DictionaryRowStatus.of(enabled: true, phase: .failed(.serviceFailed)) == .failed)
    }

    /// A ready row draws nothing extra; every other status has its own symbol and its own words.
    @Test func everyOtherStatusHasASymbolAndWords() {
        #expect(DictionaryRowStatus.ready.symbol == nil)
        let others = DictionaryRowStatus.allCases.filter { $0 != .ready }
        #expect(Set(others.compactMap(\.symbol)).count == others.count)
        let words = DictionaryRowStatus.allCases.map { String(localized: $0.label) }
        #expect(Set(words).count == words.count, "\(words)")
    }

    static func items() -> [DictionaryFilter.Item] {
        [
            .init(id: ids[0], name: "Oxford Advanced Learner’s", language: "English", status: .ready),
            .init(id: ids[1], name: "Collins", language: "English-Chinese", status: .off),
            .init(id: ids[2], name: "Larousse", language: "French", status: .missing),
            .init(id: ids[3], name: "Duden", language: "German", status: .importing),
            .init(id: ids[4], name: "Le Petit Robert", language: "French", status: .ready),
        ]
    }

    @Test func noQueryShowsEverythingInOrder() {
        #expect(DictionaryFilter.visible(Self.items(), query: "  ", selection: nil) == Self.ids)
    }

    /// Name or language, case- and diacritic-blind, in the library's order — and a row in trouble or under way stays.
    @Test func aQueryKeepsOrderAndRowsThatNeedTheReader() {
        let french = DictionaryFilter.visible(Self.items(), query: "french", selection: nil)
        #expect(french == [Self.ids[2], Self.ids[3], Self.ids[4]], "Larousse matches; Duden is importing")
        let oxford = DictionaryFilter.visible(Self.items(), query: "learners", selection: nil)
        #expect(oxford == [Self.ids[0], Self.ids[2], Self.ids[3]])
        let accent = DictionaryFilter.visible(Self.items(), query: "LAROUSSÉ", selection: nil)
        #expect(accent.first == Self.ids[2])
    }

    /// The selected row is never hidden by typing.
    @Test func theSelectionStaysVisible() {
        let shown = DictionaryFilter.visible(Self.items(), query: "robert", selection: Self.ids[1])
        #expect(shown == [Self.ids[1], Self.ids[2], Self.ids[3], Self.ids[4]])
    }

    /// No match is said differently from an empty library, and only a query can make one.
    @Test func noMatchIsNotAnEmptyLibrary() {
        let ready = Self.items().filter { $0.status == .ready || $0.status == .off }
        #expect(DictionaryFilter.visible(ready, query: "zzz", selection: nil).isEmpty)
        #expect(DictionaryFilter.isFiltering("zzz"))
        #expect(!DictionaryFilter.isFiltering(" "))
        #expect(String(localized: DictionaryFilter.noMatch) != String(localized: DictionaryFilter.emptyLibrary))
    }
}

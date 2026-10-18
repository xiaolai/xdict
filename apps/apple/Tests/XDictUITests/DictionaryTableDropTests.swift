import AppKit
import Foundation
import Testing
@testable import XDictUI

/// **The table takes drops two ways, never both** (ADR-0012 d.2): a drag from the table reorders; files and folders
/// from elsewhere import. And the keys the Library window had (d.2: Delete and Move Up/Down keep their keys).
struct DictionaryTableDropTests {
    static let file = URL(fileURLWithPath: "/tmp/a/oald.mdx")
    static let folder = URL(fileURLWithPath: "/tmp/a/", isDirectory: true)
    static let mdd = URL(fileURLWithPath: "/tmp/a/oald.mdd")

    @Test func aFileFromElsewhereImports() {
        #expect(DictionaryTable.classify(fromTable: false, rows: [], urls: [Self.file]) == .importFiles([Self.file]))
    }

    @Test func aFolderImports() {
        #expect(DictionaryTable.classify(fromTable: false, rows: [], urls: [Self.folder]) == .importFiles([Self.folder]))
    }

    /// A lone .mdd goes to the library, which says it needs its .mdx (a notice), rather than being refused unread.
    @Test func aLoneMddImports() {
        #expect(DictionaryTable.classify(fromTable: false, rows: [], urls: [Self.mdd]) == .importFiles([Self.mdd]))
    }

    @Test func severalURLsImportTogetherAndNonFileURLsAreLeftOut() {
        let web = URL(string: "https://example.com/x.mdx")!
        #expect(DictionaryTable.classify(fromTable: false, rows: [], urls: [Self.file, web, Self.mdd])
                == .importFiles([Self.file, Self.mdd]))
    }

    /// Nothing usable: refused, so the drag shows it will not be taken.
    @Test func nothingUsableIsRefused() {
        #expect(DictionaryTable.classify(fromTable: false, rows: [], urls: []) == .refuse)
        #expect(DictionaryTable.classify(fromTable: false, rows: [], urls: [URL(string: "https://example.com")!])
                == .refuse)
    }

    /// From the table: a reorder, even if the pasteboard also carries file URLs.
    @Test func aDragFromTheTableReordersNeverImports() {
        let id = UUID().uuidString
        #expect(DictionaryTable.classify(fromTable: true, rows: [id], urls: [Self.file]) == .reorder([id]))
        #expect(DictionaryTable.classify(fromTable: true, rows: [], urls: [Self.file]) == .refuse)
    }

    /// Onto a row or onto empty space, an import targets the whole table, not a gap between rows.
    @Test func anImportTargetsTheWholeTable() {
        #expect(DictionaryTable.dropRow(for: .importFiles([Self.file]), proposed: 2) == (-1, .on))
        #expect(DictionaryTable.dropRow(for: .importFiles([Self.file]), proposed: 7) == (-1, .on))
        #expect(DictionaryTable.dropRow(for: .reorder(["x"]), proposed: 2) == (2, .above))
    }

    // MARK: - Keys

    @Test func deleteRemoves() {
        #expect(DictionaryTable.keyAction(keyCode: 51, flags: []) == .remove)
        #expect(DictionaryTable.keyAction(keyCode: 117, flags: []) == .remove)
    }

    @Test func optionCommandArrowsMove() {
        #expect(DictionaryTable.keyAction(keyCode: 126, flags: [.command, .option]) == .moveUp)
        #expect(DictionaryTable.keyAction(keyCode: 125, flags: [.command, .option]) == .moveDown)
        #expect(DictionaryTable.keyAction(keyCode: 126, flags: []) == nil)
    }

    @Test func spaceToggles() {
        #expect(DictionaryTable.keyAction(keyCode: 49, flags: []) == .toggle)
        #expect(DictionaryTable.keyAction(keyCode: 49, flags: [.command]) == nil)
    }
}

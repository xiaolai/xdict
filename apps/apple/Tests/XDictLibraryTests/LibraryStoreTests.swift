import Foundation
import Testing
import XDictContract
import XDictLibrary

/// **The library is the reader's own data, in the app's Application Support** (ADR-0009 decision 2): written whole and
/// atomically, read back exactly, and never overwritten when it cannot be read — a damaged or newer file is kept as it
/// is and named, and the library refuses to save over it.
struct LibraryStoreTests {
    static func document() -> LibraryDocument {
        let file = StoredFile(id: UUID(), role: .mdx, order: 0, pathInPackage: nil, fileName: "a.mdx",
                              location: StoredLocation(bookmark: Data([1, 2, 3]), path: "/x/a.mdx"))
        var entry = LibraryEntry(id: UUID(), root: StoredLocation(bookmark: Data([4]), path: "/x"), files: [file],
                                 languages: Languages(proposal: LanguageProposal.from(fileName: "a")))
        entry.edition = Edition(rawValue: "mdx-sha256-v1:00")
        entry.lineage = LineageId(rawValue: "6f1c4a1e-0000-4000-8000-000000000000")
        entry.readersName = "Mine"
        entry.enabled = false
        entry.notes = [.missingVolume(fileName: "a.1.mdd")]
        return LibraryDocument(entries: [entry])
    }

    @Test func aDocumentReadsBackExactly() throws {
        let dir = try Scratch()
        let store = LibraryStore(directory: dir.url)
        #expect(try store.load() == nil, "no file is an empty library, not an error")
        let document = Self.document()
        try store.save(document)
        #expect(try store.load() == document)
        // Written whole: no temporary file left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path) == [LibraryStore.fileName])
    }

    @Test func aDamagedFileIsNamedAndNeverOverwritten() throws {
        let dir = try Scratch()
        let store = LibraryStore(directory: dir.url)
        let file = dir.url.appending(path: LibraryStore.fileName)
        try Data("not a library".utf8).write(to: file)
        #expect(throws: LibraryStoreError.damaged) { try store.load() }
        #expect(try Data(contentsOf: file) == Data("not a library".utf8))
    }

    @Test func aNewerLibraryIsNamedAndNeverOverwritten() throws {
        let dir = try Scratch()
        let store = LibraryStore(directory: dir.url)
        let newer = Data(#"{"version": 99, "entries": []}"#.utf8)
        try newer.write(to: dir.url.appending(path: LibraryStore.fileName))
        #expect(throws: LibraryStoreError.newerVersion(99)) { try store.load() }
        #expect(try Data(contentsOf: dir.url.appending(path: LibraryStore.fileName)) == newer)
    }
}

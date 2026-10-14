import Foundation
import Testing
import XDictLibrary

/// **Where a file is now** (ADR-0009 decision 1; L5): each file is kept as a security-scoped bookmark beside the path it
/// was last found at. A moved folder is followed by the bookmark, and the bookmark renewed; with relinking off (the
/// E2E positive control) the old path is all there is. Whatever is handed on is the file's own canonical path, so a
/// link put in a file's place is refused rather than followed.
struct FileLocatorTests {
    @Test func aMovedFolderIsFollowedAndTheBookmarkRenewed() throws {
        let dir = try Scratch()
        try dir.files("a/x.mdx")
        let stored = try FileLocator.store(dir.url.appending(path: "a/x.mdx"))
        #expect(stored.path == dir.url.appending(path: "a/x.mdx").path)
        try FileManager.default.moveItem(at: dir.url.appending(path: "a"), to: dir.url.appending(path: "b"))
        guard case .found(let url, let renewed) = FileLocator(relinking: true).resolve(stored) else {
            Issue.record("a moved file was not found by its bookmark")
            return
        }
        #expect(url.path == dir.url.appending(path: "b/x.mdx").path)
        #expect(renewed?.path == url.path, "the stored location follows the move")
    }

    @Test func withRelinkingOffAMovedFileIsMissing() throws {
        let dir = try Scratch()
        try dir.files("a/x.mdx")
        let stored = try FileLocator.store(dir.url.appending(path: "a/x.mdx"))
        guard case .found = FileLocator(relinking: false).resolve(stored) else {
            Issue.record("a file where it was is found without relinking")
            return
        }
        try FileManager.default.moveItem(at: dir.url.appending(path: "a"), to: dir.url.appending(path: "b"))
        #expect(FileLocator(relinking: false).resolve(stored) == .missing)
    }

    @Test func aFileGoneEverywhereIsMissing() throws {
        let dir = try Scratch()
        try dir.files("x.mdx")
        let stored = try FileLocator.store(dir.url.appending(path: "x.mdx"))
        try FileManager.default.removeItem(at: dir.url.appending(path: "x.mdx"))
        #expect(FileLocator(relinking: true).resolve(stored) == .missing)
    }

    /// The file replaced by a link to somewhere else: never followed.
    @Test func aLinkInAFilesPlaceIsRefused() throws {
        let dir = try Scratch()
        try dir.files("d/x.mdx", "elsewhere/secret.mdx")
        let stored = try FileLocator.store(dir.url.appending(path: "d/x.mdx"))
        try FileManager.default.removeItem(at: dir.url.appending(path: "d/x.mdx"))
        try dir.link("d/x.mdx", to: "../elsewhere/secret.mdx")
        for relinking in [true, false] {
            let resolved = FileLocator(relinking: relinking).resolve(stored)
            #expect(resolved == .notCanonical || resolved == .missing, "relinking \(relinking): \(resolved)")
            if case .found(let url, _) = resolved { Issue.record("followed a link to \(url.path)") }
        }
    }

    @Test func containmentIsByCanonicalPath() throws {
        let dir = try Scratch()
        #expect(FileLocator.isInside(dir.url.appending(path: "a/b.mdx"), dir.url.appending(path: "a")))
        #expect(!FileLocator.isInside(dir.url.appending(path: "ab/b.mdx"), dir.url.appending(path: "a")))
        #expect(!FileLocator.isInside(dir.url.appending(path: "a"), dir.url.appending(path: "a")))
    }
}

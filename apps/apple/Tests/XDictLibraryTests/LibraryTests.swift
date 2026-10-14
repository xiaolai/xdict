import Foundation
import Testing
import XDictClient
import XDictContract
import XDictLibrary

/// **The reader's library, against a fake of the service** (plan-macos-v1 WI-5): what is added is registered and
/// answers, an import can be cancelled and retried, a refusal stays named, the reader's order, names, languages and
/// choices survive a relaunch, moved files are found again, a changed edition is asked about and joined only when the
/// reader says so, and the join undoes exactly. The real service's half is `LibraryServiceTests` (XDictServiceTests).
@MainActor
struct LibraryTests {
    let dir: Scratch
    let backend = FakeBackend()
    let storeDir: URL

    init() throws {
        dir = try Scratch()
        storeDir = dir.url.appending(path: "store")
    }

    func library(relinking: Bool = true) -> Library {
        Library(store: LibraryStore(directory: storeDir), backend: backend, options: Library.Options(relinking: relinking))
    }

    func waitUntilHeld() async {
        for _ in 0..<500 where await backend.heldCount == 0 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func whatIsAddedIsRegisteredOpenedAndKept() async throws {
        try dir.files("d/a.mdx", "d/a.mdd", "d/a.css")
        let library = library()
        await library.start()
        let added = library.add([dir.url.appending(path: "d")])
        await library.settle()
        let entry = try #require(library.entries.first)
        #expect(added == [entry.id] && library.phases[entry.id] == .ready)
        #expect(entry.files.map(\.role) == [.mdx, .mdd, .sidecar])
        #expect(entry.files.map(\.fileName) == ["a.mdx", "a.mdd", "a.css"])
        #expect(entry.files.allSatisfy { !$0.location.bookmark.isEmpty }, "every file has its bookmark")
        #expect(entry.edition != nil && entry.lineage != nil && entry.info?.title == "Title of a.mdx")
        #expect(library.answering.count == 1)
        let reloaded = try #require(try LibraryStore(directory: storeDir).load())
        #expect(reloaded.entries == library.entries)
    }

    @Test func cancelThenRetryCompletes() async throws {
        try dir.files("a.mdx")
        let library = library()
        await library.start()
        await backend.hold()
        let id = try #require(library.add([dir.url.appending(path: "a.mdx")]).first)
        await waitUntilHeld()
        #expect(library.phases[id].map { if case .importing = $0 { true } else { false } } == true)
        await library.cancelImport(id)
        await library.settle()
        #expect(library.phases[id] == .cancelled)
        #expect(library.entries.first?.edition == nil)
        await backend.release()
        library.retry(id)
        await library.settle()
        #expect(library.phases[id] == .ready)
        #expect(await backend.imports == ["a.mdx", "a.mdx"])
    }

    @Test func aRefusalIsKeptWithItsReasonAndNotRetriedAtLaunch() async throws {
        try dir.files("locked.mdx")
        await backend.fail("locked.mdx", with: .wire(.core(.unsupported(feature: .registrationCode, detail: ""))))
        let library = library()
        await library.start()
        let id = try #require(library.add([dir.url.appending(path: "locked.mdx")]).first)
        await library.settle()
        #expect(library.phases[id] == .refused(.registrationCode))
        #expect(library.entries.first?.refusal == .registrationCode)
        let relaunched = self.library()
        await relaunched.start()
        await relaunched.settle()
        #expect(relaunched.phases[id] == .refused(.registrationCode))
        #expect(await backend.imports == ["locked.mdx"], "a permanent refusal is not asked again at launch")
    }

    @Test func anUnreadableVolumeBecomesANoteNamingIt() async throws {
        try dir.files("v/v.mdx", "v/v.mdd")
        let library = library()
        await library.start()
        await backend.hold()
        let id = try #require(library.add([dir.url.appending(path: "v")]).first)
        let volume = try #require(library.entries.first?.files.first { $0.role == .mdd })
        await waitUntilHeld()
        await backend.setProblems("v.mdx") { _ in
            [.volumeUnreadable(name: volume.id.uuidString, error: .unsupported(feature: .resourceLibraryV3, detail: ""))]
        }
        await backend.release()
        await library.settle()
        #expect(library.phases[id] == .ready)
        #expect(library.entries.first?.notes == [.volumeUnreadable(fileName: "v.mdd", reason: .resourceLibraryV3)])
    }

    @Test func theReadersChoicesSurviveARelaunch() async throws {
        try dir.files("a/a.mdx", "b/b.mdx", "c/c.mdx")
        let library = library()
        await library.start()
        _ = library.add([dir.url.appending(path: "a"), dir.url.appending(path: "b"), dir.url.appending(path: "c")])
        await library.settle()
        let ids = library.entries.map(\.id)
        try #require(ids.count == 3)
        library.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        library.moveDown(ids[0])
        library.setEnabled(ids[1], false)
        library.rename(ids[1], "Bee")
        library.setLanguages(ids[2], LanguagePair(search: "en", explanation: "fr"))
        let relaunched = self.library()
        await relaunched.start()
        await relaunched.settle()
        #expect(relaunched.entries.map(\.id) == [ids[2], ids[1], ids[0]])
        #expect(relaunched.entries.map(\.displayName) == ["Title of c.mdx", "Bee", "Title of a.mdx"])
        #expect(relaunched.entries.map(\.enabled) == [true, false, true])
        let languages = try #require(relaunched.entries.first?.languages)
        #expect(languages.pair == LanguagePair(search: "en", explanation: "fr") && languages.confirmed)
        #expect(relaunched.answering.count == 2, "a disabled dictionary does not answer")
    }

    @Test func aGuessIsAskedAndAStatedPairIsNot() async throws {
        try dir.files("l/Plain Glossary.mdx", "l/汉英词典.mdx")
        let library = library()
        await library.start()
        _ = library.add([dir.url.appending(path: "l")])
        await library.settle()
        let plain = try #require(library.entries.first { $0.mdx?.fileName == "Plain Glossary.mdx" })
        let stated = try #require(library.entries.first { $0.mdx?.fileName == "汉英词典.mdx" })
        #expect(plain.languages.needsAsking && !stated.languages.needsAsking)
        library.confirmLanguages(plain.id)
        #expect(library.entries.first { $0.id == plain.id }?.languages.needsAsking == false)
    }

    /// **L5**: the reader moves the folder; at the next launch every dictionary is found by its bookmark, in its order.
    /// With relinking off, the same move leaves them missing: the positive control.
    @Test func movedFilesAreFoundAgainAndOnlyByRelinking() async throws {
        try dir.files("lib/a/a.mdx", "lib/b/b.mdx")
        let library = library()
        await library.start()
        _ = library.add([dir.url.appending(path: "lib")])
        await library.settle()
        let ids = library.entries.map(\.id)
        try FileManager.default.moveItem(at: dir.url.appending(path: "lib"), to: dir.url.appending(path: "moved"))
        let unlinked = self.library(relinking: false)
        await unlinked.start()
        await unlinked.settle()
        #expect(unlinked.entries.allSatisfy { unlinked.phases[$0.id] == .missing(fileName: $0.mdx?.fileName ?? "") })
        #expect(unlinked.entries.count == 2)
        let relinked = self.library()
        await relinked.start()
        await relinked.settle()
        #expect(relinked.entries.map(\.id) == ids)
        #expect(ids.allSatisfy { relinked.phases[$0] == .ready })
        #expect(relinked.entries.allSatisfy { $0.mdx?.location.path.contains("/moved/") == true }, "the new place is kept")
    }

    /// One dictionary's folder moved out of the folder the reader chose: its bookmarks follow it, and its files are
    /// held inside the MDX's own folder instead, so it is found rather than refused as having left its folder.
    @Test func aDictionaryFolderMovedOutOfTheChosenFolderIsFollowed() async throws {
        try dir.files("lib/a/a.mdx", "lib/a/a.mdd", "lib/a/a.css", "lib/b/b.mdx")
        let library = library()
        await library.start()
        _ = library.add([dir.url.appending(path: "lib")])
        await library.settle()
        let a = try #require(library.entries.first { $0.mdx?.fileName == "a.mdx" })
        #expect(a.files.count == 3)
        try FileManager.default.moveItem(at: dir.url.appending(path: "lib/a"), to: dir.url.appending(path: "elsewhere"))
        let relaunched = self.library()
        await relaunched.start()
        await relaunched.settle()
        #expect(relaunched.phases[a.id] == .ready)
        #expect(relaunched.entries.first { $0.id == a.id }?.files.allSatisfy { $0.location.path.contains("/elsewhere/") } == true)
    }

    /// **A relink while a dictionary is open keeps the folder rule** (the security review of 2026-10-15): when a file's
    /// path answers ENOENT, the library finds it again, and takes the new place only if the package still holds by the
    /// rule `resolve()` applies. A sidecar moved out of its folder alone is not followed there.
    @Test func aFileMovedOutOfItsFolderWhileOpenIsNotFollowed() async throws {
        try dir.files("lib/a/a.mdx", "lib/a/a.css", "elsewhere/.keep")
        let library = library()
        await library.start()
        _ = library.add([dir.url.appending(path: "lib")])
        await library.settle()
        let package = try #require(await backend.opened["a.mdx"])
        let css = try #require(package.files.first { $0.spec.role == .sidecar })
        let before = css.locate()
        try FileManager.default.moveItem(at: dir.url.appending(path: "lib/a/a.css"), to: dir.url.appending(path: "elsewhere/a.css"))
        #expect(css.locate() == before, "a file moved out of its folder was followed there: \(css.locate().path)")
    }

    /// The other half: the dictionary's whole folder moved out of the one the reader chose, while it is open. Each file's
    /// new place is outside the folder its package was held to, so the whole package is resolved again by `resolve()`'s
    /// rule, which holds it to the MDX's own folder: every file is followed.
    @Test func aFolderMovedWhileOpenIsFollowed() async throws {
        try dir.files("lib/a/a.mdx", "lib/a/a.css")
        let library = library()
        await library.start()
        _ = library.add([dir.url.appending(path: "lib")])
        await library.settle()
        let package = try #require(await backend.opened["a.mdx"])
        try FileManager.default.moveItem(at: dir.url.appending(path: "lib/a"), to: dir.url.appending(path: "elsewhere"))
        for file in package.files {
            #expect(file.locate().path.contains("/elsewhere/"), "\(file.spec.role) not followed: \(file.locate().path)")
        }
    }

    /// An import that never ends is a wait that ends: `settled(within:)` says it is not settled, rather than hanging.
    @Test func aWaitForAnImportThatNeverEndsEnds() async throws {
        try dir.files("a.mdx")
        let library = library()
        await library.start()
        await backend.hold()
        _ = library.add([dir.url.appending(path: "a.mdx")])
        await waitUntilHeld()
        #expect(await library.settled(within: .milliseconds(200)) == false)
        await backend.release()
        #expect(await library.settled(within: .seconds(30)))
    }

    /// A stale bookmark (the file copied elsewhere and the original gone): the reader adds the copy, its edition
    /// matches, and the dictionary they had is relinked rather than added twice.
    @Test func aReAddedFileOfTheSameEditionRelinksTheMissingDictionary() async throws {
        try dir.files("old/a.mdx")
        let library = library()
        await library.start()
        _ = library.add([dir.url.appending(path: "old")])
        await library.settle()
        let original = try #require(library.entries.first)
        library.rename(original.id, "Kept")
        try FileManager.default.createDirectory(at: dir.url.appending(path: "new"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir.url.appending(path: "old/a.mdx"), to: dir.url.appending(path: "new/a.mdx"))
        try FileManager.default.removeItem(at: dir.url.appending(path: "old"))
        let relaunched = self.library()
        await relaunched.start()
        await relaunched.settle()
        #expect(relaunched.phases[original.id] == .missing(fileName: "a.mdx"))
        _ = relaunched.add([dir.url.appending(path: "new/a.mdx")])
        await relaunched.settle()
        #expect(relaunched.entries.map(\.id) == [original.id])
        #expect(relaunched.entries.first?.displayName == "Kept")
        #expect(relaunched.phases[original.id] == .ready)
        #expect(relaunched.notices.contains(.relinked(name: "Kept")))
    }

    @Test func theSameFileAddedTwiceIsOneDictionary() async throws {
        try dir.files("a.mdx")
        let library = library()
        await library.start()
        _ = library.add([dir.url.appending(path: "a.mdx")])
        await library.settle()
        #expect(library.add([dir.url.appending(path: "a.mdx")]).isEmpty)
        #expect(library.entries.count == 1)
        #expect(library.notices.contains(.alreadyInLibrary(name: "Title of a.mdx")))
    }

    /// **ADR-0002 decision 3**: a rewritten file is a new edition with a lineage of its own until the reader says it is
    /// the same dictionary; the join is made with the lineage it had, and undone with the one the import gave it.
    @Test func aChangedEditionIsJoinedOnlyWhenTheReaderSaysSoAndTheJoinUndoes() async throws {
        try dir.files("r/r.mdx")
        let library = library()
        await library.start()
        let id = try #require(library.add([dir.url.appending(path: "r")]).first)
        await library.settle()
        let first = try #require(library.entries.first)
        let (e1, l1) = (try #require(first.edition), try #require(first.lineage))
        try Data("rewritten".utf8).write(to: dir.url.appending(path: "r/r.mdx"))
        await library.refresh()
        await library.settle()
        let changed = try #require(library.entries.first)
        let offer = try #require(changed.offer, "a changed edition is asked about")
        #expect(changed.edition != e1 && changed.lineage != l1)
        #expect(offer.earlierEdition == e1 && offer.earlierLineage == l1 && offer.mintedLineage == changed.lineage)
        #expect(await backend.lineageCalls.isEmpty, "nothing is joined unasked")

        #expect(await library.acceptJoin(id))
        #expect(library.entries.first?.lineage == l1 && library.entries.first?.offer == nil)
        #expect(await backend.lineageCalls == [.join(offer.edition, l1)])
        #expect(try LibraryStore(directory: storeDir).load()?.entries.first?.join?.previous == offer.mintedLineage)

        #expect(await library.undoJoin(id))
        #expect(library.entries.first?.lineage == offer.mintedLineage && library.entries.first?.join == nil)
        #expect(library.entries.first?.offer == offer, "the question can be answered again")
        #expect(await backend.lineageCalls == [.join(offer.edition, l1), .split(offer.edition, offer.mintedLineage)])
        #expect(await backend.lineage(of: offer.edition) == offer.mintedLineage)

        library.declineJoin(id)
        #expect(library.entries.first?.offer == nil)
    }

    /// **The library is the reader's data**: one that cannot be read is named, nothing is added to it, and the file is
    /// left exactly as it was.
    @Test func anUnreadableLibraryIsNeverWrittenOver() async throws {
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let file = storeDir.appending(path: LibraryStore.fileName)
        try Data("damaged".utf8).write(to: file)
        try dir.files("a.mdx")
        let library = library()
        await library.start()
        #expect(library.unreadable == .damaged)
        #expect(library.add([dir.url.appending(path: "a.mdx")]).isEmpty)
        #expect(try Data(contentsOf: file) == Data("damaged".utf8))
    }

    @Test func removingADictionaryClosesItAndForgetsIt() async throws {
        try dir.files("a.mdx")
        let library = library()
        await library.start()
        let id = try #require(library.add([dir.url.appending(path: "a.mdx")]).first)
        await library.settle()
        await library.remove(id)
        #expect(library.entries.isEmpty && library.phases[id] == nil)
        #expect(await backend.closed.count == 1)
        #expect(try LibraryStore(directory: storeDir).load()?.entries.isEmpty == true)
    }
}

extension FakeBackend {
    func setProblems(_ name: String, _ make: @escaping @Sendable (String) -> [Problem]) { problems[name] = make }
}

extension Library {
    /// Settled within half a minute, or the test fails here: an import that never ends must not hang the suite.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        let settled = await settled(within: .seconds(30))
        #expect(settled, "the library was still working after 30 s", sourceLocation: sourceLocation)
    }
}

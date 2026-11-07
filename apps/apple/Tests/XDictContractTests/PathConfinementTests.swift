import Foundation
import Testing
import XDictContract

/// **A path the contract carries cannot lead into the service's own container** (audit 2026-11-05 L1): the word pack's
/// and the sync pass's folders are the app group's, and the sandbox closes everything else but the service's own
/// container — its registry, the ledger in it, its indexes — which admission closes here.
struct PathConfinementTests {
    /// A container of the test's own: `service/` stands for the service's container, `group/` for the app group's.
    struct Folders {
        let root: URL
        var service: URL { root.appending(path: "service") }
        var registry: URL { service.appending(path: "Library/Application Support/registry") }
        var group: URL { root.appending(path: "group") }
        var wordPack: URL { AppGroup.wordPack(in: group).appending(path: AppGroup.wordPackFile) }
        var confinement: PathConfinement { PathConfinement(forbidden: [service]) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "xdict-confine-\(UUID().uuidString)")
            for folder in [registry, AppGroup.wordPack(in: group), AppGroup.sync(in: group)] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func aPathIntoTheRegistryIsRefused() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let ledger = folders.registry.appending(path: "ledger.xdlog").path(percentEncoded: false)
        #expect(folders.confinement.refusal(ledger) == .forbiddenPath, "the ledger was reachable")
        #expect(folders.confinement.refusal(folders.service.path(percentEncoded: false)) == .forbiddenPath,
                "the container itself was reachable")
    }

    @Test func theDesignatedWordPackPathIsAccepted() throws {
        let folders = try Folders()
        defer { folders.remove() }
        #expect(folders.confinement.refusal(folders.wordPack.path(percentEncoded: false)) == nil)
        let inbox = AppGroup.sync(in: folders.group).appending(path: "in").path(percentEncoded: false)
        #expect(folders.confinement.refusal(inbox) == nil, "a folder not yet made is still the group's")
    }

    /// A link the app group holds is followed before the comparison, a `..` step is refused outright (it is read
    /// through links by the system, not by the text), and only an absolute path is a place.
    @Test func noLinkOrStepLeadsIn() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let link = AppGroup.wordPack(in: folders.group).appending(path: "pack.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folders.registry.appending(path: "x"))
        #expect(folders.confinement.refusal(link.path(percentEncoded: false)) == .forbiddenPath, "a dangling link led in")
        let folderLink = folders.group.appending(path: "WordPackLink")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folders.registry)
        #expect(folders.confinement.refusal(folderLink.appending(path: "new.jsonl").path(percentEncoded: false))
                == .forbiddenPath, "a linked folder led in")
        let stepped = folders.group.path(percentEncoded: false) + "/../service/Library/x"
        #expect(folders.confinement.refusal(stepped) == .forbiddenPath)
        #expect(folders.confinement.refusal("WordPack/xdict-words-en.jsonl") == .forbiddenPath, "a relative path")
    }

    /// **Admission asks it for every path an operation names**, and a request that names none is not affected.
    @Test func admissionRefusesEachPathCarryingOperation() throws {
        let folders = try Folders()
        defer { folders.remove() }
        let inside = folders.registry.appending(path: "out").path(percentEncoded: false)
        let pack = folders.wordPack.path(percentEncoded: false)
        let inbox = AppGroup.sync(in: folders.group).appending(path: "in").path(percentEncoded: false)
        let refused: [ServiceOperation] = [
            .setWordPack(path: inside),
            .buildWordPack(sources: inbox, manifest: inbox, output: inside),
            .ledgerSync(input: inbox, output: inside, device: "d"),
        ]
        for operation in refused {
            #expect(Fixtures.request(operation).refusal(handles: [], filesOf: Fixtures.filesOf,
                                                        confinement: folders.confinement) == .forbiddenPath,
                    "\(operation)")
        }
        let accepted: [ServiceOperation] = [
            .setWordPack(path: pack), .buildWordPack(sources: inbox, manifest: inbox, output: pack),
            .ledgerSync(input: inbox, output: inbox, device: "d"), .wordPack,
        ]
        for operation in accepted {
            #expect(Fixtures.request(operation).refusal(handles: [], filesOf: Fixtures.filesOf,
                                                        confinement: folders.confinement) == nil, "\(operation)")
        }
        let envelope = try Fixtures.request(.setWordPack(path: inside)).encoded()
        guard case .answered(let response) = Request.receive(envelope, handles: [], filesOf: Fixtures.filesOf,
                                                             confinement: folders.confinement) else {
            Issue.record("a path into the container was admitted")
            return
        }
        #expect(response.outcome == .failure(.refused(.forbiddenPath)))
    }
}

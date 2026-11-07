import Foundation
import Testing
import XDictClient
import XDictContract
@testable import XDictService

/// **The real service refuses a path into its own folders before the core sees it** (audit 2026-11-05 L1): the
/// harness's registry stands for the container's, and a word pack in a folder of the app group's kind is still read.
struct PathConfinementServiceTests {
    @Test func aPathIntoTheRegistryIsRefusedAndTheDesignatedPackPathIsNot() async throws {
        let harness = try ServiceHarness()
        let client = harness.client()
        let ledger = harness.storage.appending(path: "registry/ledger.xdlog").path(percentEncoded: false)
        let refused = await client.call(.setWordPack(path: ledger))
        guard case .failure(.wire(.refused(.forbiddenPath))) = refused else {
            Issue.record("a path into the registry reached the core: \(refused)")
            return
        }
        let synced = await client.call(.ledgerSync(input: ledger, output: ledger, device: "d"))
        guard case .failure(.wire(.refused(.forbiddenPath))) = synced else {
            Issue.record("a sync into the registry reached the core: \(synced)")
            return
        }

        let group = try ServiceHarness.scratch()
        defer { try? FileManager.default.removeItem(at: group) }
        let folder = AppGroup.wordPack(in: group)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pack = folder.appending(path: AppGroup.wordPackFile)
        try Data("not a pack\n".utf8).write(to: pack)
        let answered = await client.call(.setWordPack(path: pack.path(percentEncoded: false)))
        if case .failure(.wire(.refused(let refusal))) = answered {
            Issue.record("the designated pack path was refused by admission: \(refusal)")
        }
    }
}

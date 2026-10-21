import Foundation
import Testing
import XDictUI

/// **The files of one sync pass** (plan-history-and-learning §2.6): the service is sandboxed, so the app copies the
/// reader's folder's logs into the app group's inbox and this device's log back out. Staging leaves a stray file and an
/// oversized one out, and a pass starts from an empty inbox; collecting replaces this device's own log from the last pass.
struct SyncStagingTests {
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "xdict-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func names(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
    }

    @Test func stagingCopiesTheLogsAndLeavesAStrayFileOut() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "reader"), inbox = root.appending(path: "in")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appending(path: "xdict-a.xdlog"))
        try Data("notes".utf8).write(to: folder.appending(path: "notes.txt"))
        try Data(count: 32).write(to: folder.appending(path: "xdict-big.xdlog"))

        let staged = try SyncStaging.stage(from: folder, to: inbox, limit: 16)
        #expect(staged.copied == 1)
        #expect(staged.oversized == ["xdict-big.xdlog"])
        #expect(try Self.names(inbox) == ["xdict-a.xdlog"], "only logs, and only one the service will read")

        // A second pass starts from an empty inbox: what the service merges is exactly this pass's peers.
        try Data("stale".utf8).write(to: inbox.appending(path: "xdict-old.xdlog"))
        _ = try SyncStaging.stage(from: folder, to: inbox, limit: 16)
        #expect(try Self.names(inbox) == ["xdict-a.xdlog"])
    }

    @Test func collectingReplacesThisDevicesOwnLogFromTheLastPass() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "reader"), outbox = root.appending(path: "out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appending(path: "xdict-a.xdlog"))
        try Data("new".utf8).write(to: outbox.appending(path: "xdict-a.xdlog"))

        #expect(try SyncStaging.collect(from: outbox, to: folder) == 1)
        #expect(try Data(contentsOf: folder.appending(path: "xdict-a.xdlog")) == Data("new".utf8))
        #expect(try Self.names(folder) == ["xdict-a.xdlog"], "a peer's log is not copied around")
    }
}

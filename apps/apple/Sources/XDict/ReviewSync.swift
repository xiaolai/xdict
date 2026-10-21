import Foundation
import XDictAppleSource
import XDictBase
import XDictContract
import XDictUI
import os

/// **One sync pass as the app runs it** (plan-history-and-learning §2.6). The dictionary service is sandboxed and cannot
/// read the folder the reader chose, so the app moves the files: it stages the folder's logs into the app group's inbox,
/// the service merges them and writes this device's log to the outbox, and the app copies that back. The core owns the
/// merging; this owns the files, and nothing of a dictionary's is among them.
@MainActor
enum ReviewSync {
    private static let log = Logger(subsystem: XDictIdentity.app, category: "sync")

    static func run(study: StudyModel, folder: URL) async -> SyncReport? {
        guard let root = SharedContainer.sync() else {
            log.error("the app group's sync folder is not reachable")
            return nil
        }
        let inbox = root.appending(path: "in", directoryHint: .isDirectory)
        let outbox = root.appending(path: "out", directoryHint: .isDirectory)
        do {
            let staged = try SyncStaging.stage(from: folder, to: inbox)
            if !staged.oversized.isEmpty {
                log.error("left out, over the sync bound: \(staged.oversized.joined(separator: ", "), privacy: .public)")
            }
            guard let report = await study.sync(input: inbox.path(percentEncoded: false),
                                                output: outbox.path(percentEncoded: false)) else { return nil }
            try SyncStaging.collect(from: outbox, to: folder)
            return report
        } catch {
            log.error("sync files: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

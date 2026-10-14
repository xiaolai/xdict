import Foundation
import Synchronization
import XDictContract
@testable import XDictClient

/// What the client tests share: answers to script with, short deadlines, and a wait that gives up.
enum Fixture {
    static let versions = Versions(protocolVersion: 1, core: "0.0.1", indexFormat: 2, normalization: 1)
    static let edition = Edition(rawValue: "mdx-sha256-v1:" + String(repeating: "ab", count: 32))
    static let info = DictInfo(title: "t", description: "", formatVersion: "2.0", keys: 1)

    static func page(_ hits: [Hit] = []) -> Answer {
        .page(Page(hits: hits, total: UInt64(hits.count), generation: 0, problems: []))
    }

    static func hit(in dict: DictId) -> Hit {
        Hit(dict: dict, entry: EntryRef(edition: edition, key: "k", occurrence: 0), headword: "k", how: .exact, problems: [])
    }

    static func lookup(_ query: String, in dicts: [DictId] = []) -> ServiceOperation {
        .lookup(query: query, dicts: dicts, options: LookupOptions(limit: 10, offset: 0, mode: .reader, generation: nil))
    }

    static func resource(_ path: String, in dict: DictId = DictId(rawValue: "d"), render: RenderContext = .reader)
        -> ServiceOperation {
        .resource(dict: dict, path: path, render: render)
    }

    /// The query of a lookup request, or nil.
    static func query(_ request: Request) -> String? {
        if case .lookup(let query, _, _) = request.operation { return query }
        return nil
    }

    /// Deadlines in milliseconds, so a test waits for them: `warm` on a connection that has answered, `cold` on one that
    /// has not. An import ends after `silence` without progress; an abandoned connection is kept `grace` for late replies.
    static func options(warm: Duration = .milliseconds(60), cold: Duration = .milliseconds(600),
                        silence: Duration = .milliseconds(60), grace: Duration = .milliseconds(150)) -> ServiceClient.Options {
        ServiceClient.Options(deadline: { _, fresh in fresh ? cold : warm }, importSilence: silence, retiredGrace: grace)
    }

    /// A package of real files (the client opens each to send its handle), in a directory of the test's own.
    static func package() throws -> (DictionaryPackage, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "xdict-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mdx = directory.appending(path: "a.mdx"), mdd = directory.appending(path: "a.mdd")
        try Data("mdx".utf8).write(to: mdx)
        try Data("mdd".utf8).write(to: mdd)
        return (DictionaryPackage.of(mdx: mdx, volumes: [mdd]), directory)
    }
}

/// One value, set once from another task.
final class Slot<Value: Sendable>: Sendable {
    private let value = Mutex<Value?>(nil)
    func set(_ new: Value) { value.withLock { $0 = new } }
    var current: Value? { value.withLock { $0 } }
}

extension CallTicket {
    /// The outcome, or nil if none came within `timeout` — so a check that fails by hanging fails instead.
    func outcome(within timeout: Duration) async -> ClientOutcome? {
        let slot = Slot<ClientOutcome>()
        let ticket = self
        Task { slot.set(await ticket.outcome()) }
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if let outcome = slot.current { return outcome }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return slot.current
    }
}

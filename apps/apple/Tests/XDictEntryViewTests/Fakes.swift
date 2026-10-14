import Foundation
@testable import XDictEntryView

/// A dictionary of values: entries and resources by path, links by URL. A resource whose path is in `held` waits for
/// `release()`.
final class FakeContent: EntryContent, @unchecked Sendable {
    let binding: EntryBinding
    var documents: [String: EntryDocument] = [:]
    var resources: [String: EntryResource] = [:]
    var links: [String: EntryLink] = [:]
    var failing = false
    var held: Set<String> = []
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var askedPaths: [String] = []

    init(_ name: String) {
        binding = EntryBinding(dictionary: "lineage-\(name)", edition: "edition-\(name)", handle: "handle-\(name)")
    }

    struct Failure: Error {}

    var holding: Int { lock.withLock { waiting.count } }
    var asked: [String] { lock.withLock { askedPaths } }

    func release() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiting.removeAll() }
            return waiting
        }
        all.forEach { $0.resume() }
    }

    func entry(_ reference: EntryReference) async throws -> EntryDocument {
        guard !failing, let document = documents[reference.key] else { throw Failure() }
        return document
    }

    func resource(_ path: String) async throws -> EntryResource {
        lock.withLock { askedPaths.append(path) }
        if held.contains(path) {
            await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } }
        }
        guard !failing else { throw Failure() }
        return resources[path] ?? .missing
    }

    func link(_ url: String, origin: EntryLinkOrigin) async throws -> EntryLink {
        guard !failing, let link = links[url] else { throw Failure() }
        return link
    }
}

/// WebKit's switches as values, each fault injectable on its own.
@MainActor
final class FakeSwitches: WebKitFeatureSwitches {
    var listed: [String: Bool]? = ["LinkPreconnect": true, "PeerConnectionEnabled": true, "Other": true]
    var canSet = true
    var canRead = true
    var setterWorks = true
    private(set) var sets: [String] = []

    func features() -> [String: AnyObject]? {
        listed.map { Dictionary(uniqueKeysWithValues: $0.keys.map { ($0, $0 as NSString) }) }
    }

    func setEnabled(_ enabled: Bool, _ feature: AnyObject) {
        guard let key = feature as? String else { return }
        sets.append("\(key)=\(enabled)")
        if setterWorks { listed?[key] = enabled }
    }

    func isEnabled(_ feature: AnyObject) -> Bool {
        guard let key = feature as? String else { return true }
        return listed?[key] ?? true
    }
}

let corePolicy = "default-src xdict://d/; script-src xdict://d/ 'unsafe-inline' 'unsafe-eval'; connect-src 'none'; worker-src 'none'"

func request(_ text: String, method: String = "GET") -> URLRequest {
    var request = URLRequest(url: URL(string: text) ?? URL(fileURLWithPath: "/"))
    request.httpMethod = method
    return request
}

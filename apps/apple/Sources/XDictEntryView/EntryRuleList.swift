import Foundation
import WebKit

/// **The content rule list**: block every load, then let through only the view's own space and the schemes a page
/// makes from itself (`data:`, `blob:`, `about:`). Spike 3 measured it as the only public layer that stops link
/// `dns-prefetch` and link `preconnect`, and the one that sees dedicated and shared workers' loads, popups' loads and
/// navigations as document loads (`measurements/2026-10-14-macos-confinement`, "What the content rule list sees").
public enum EntryRuleList {
    /// Raised whenever the rules change, so a list compiled from older rules is never reused.
    public static let identifier = "ai.xdict.entry-confinement.1"

    /// The rules, in order: the first blocks everything, each later one lifts the block for its prefix.
    public static let rules: [[String: [String: String]]] = [
        ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
        ["trigger": ["url-filter": "^xdict://d/"], "action": ["type": "ignore-previous-rules"]],
        ["trigger": ["url-filter": "^data:"], "action": ["type": "ignore-previous-rules"]],
        ["trigger": ["url-filter": "^blob:"], "action": ["type": "ignore-previous-rules"]],
        ["trigger": ["url-filter": "^about:"], "action": ["type": "ignore-previous-rules"]],
    ]

    /// The rules as WebKit takes them.
    public static func encoded() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The list compiled into a store of its own under `directory` (the app's Caches): never the default store, whose
    /// lists another WebKit client of this app could replace. Compiled once per process by the caller.
    @MainActor
    public static func compile(in directory: URL) async throws -> WKContentRuleList {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: directory) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: directory.path])
        }
        let rules = try encoded()
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
    }
}

import AppKit
import Foundation

/// Hands a URL to the reader's default browser. The one place XDict lets an entry's remote link leave the machine,
/// and only after `RemoteOpenGate` has the reader's yes.
@MainActor
public protocol EntryURLOpener {
    func open(_ url: URL)
}

/// The production opener: the default browser, through Launch Services.
public struct WorkspaceOpener: EntryURLOpener {
    public init() {}
    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// **The reader's consent, and nothing else, opens a remote link** (the owner's decision, 2026-10-14, ADR-0009
/// decision 7). A remote link the reader — or a script — activates is never loaded by the web view; XDict asks in its
/// own window, "Open example.com in your browser?", and only the reader's answer reaches the opener. A script can raise
/// the question but cannot answer it: the answer is a native button, outside the page.
///
/// One question at a time: while it is asked, every other request is dropped and logged, so a page that activates
/// links in a loop raises one prompt, not a stack of them.
@MainActor
public final class RemoteOpenGate {
    public enum Request: Equatable, Sendable {
        case ask(URL, host: String)
        case drop(String)
    }

    public private(set) var asking: URL?

    public init() {}

    public func request(_ url: URL) -> Request {
        guard asking == nil else { return .drop("a question is already being asked") }
        guard let openable = Self.openable(url.absoluteString), let host = openable.host(percentEncoded: false) else {
            return .drop("not a URL a browser opens: \(url.absoluteString)")
        }
        asking = openable
        return .ask(openable, host: host)
    }

    /// The reader's answer to the question being asked: the URL to open on a yes, nothing on a no. An answer with no
    /// question opens nothing.
    public func answer(consent: Bool) -> URL? {
        defer { asking = nil }
        return consent ? asking : nil
    }

    /// `text` as a URL a browser should be handed: `http` or `https`, with a host, no credentials. Anything else is
    /// never offered.
    nonisolated public static func openable(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, let url = parts.url else { return nil }
        return url
    }
}

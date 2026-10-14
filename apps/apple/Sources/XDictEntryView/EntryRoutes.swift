import Foundation

/// **The one space of URLs the entry view serves** (ADR-0007 decision 14, made exact 2026-10-14): the core writes every
/// entry under `xdict://d/`, as `entry/…` (a lookup), `r/…` (a resource), `sound/…` (a recording) and `blocked/…` (a
/// remote URL it saw and refused). The scheme handler answers that authority and those routes, and refuses everything
/// else; it never redirects.
public enum EntryRoutes {
    public static let scheme = "xdict"
    public static let authority = "d"
    /// The view's base, which the core is asked to render under (the contract's `RenderContext.baseURL`).
    public static let base = "xdict://d/"

    /// What a request asks for, read from its URL and method alone.
    public enum Route: Equatable, Sendable {
        /// `entry/…`: only the document the view itself is loading is ever served under it; any other is refused.
        case document(URL)
        /// `r/…`, the path as it travels (still percent-encoded, a query kept: the core tries it with and without).
        case resource(path: String)
        /// `sound/…`, likewise: a recording an `<audio>` element asks for.
        case sound(path: String)
        /// `blocked/…`: the remote URL the core refused, decoded once. Answered with a placeholder naming its host.
        case blocked(remote: String)
        case refused(Refusal)
    }

    /// Why a request was refused before anything was asked of the dictionary. Logged, never shown.
    public enum Refusal: String, Sendable, CaseIterable {
        case notThisScheme, notThisAuthority, credentialsOrPort, unknownRoute, emptyPath, notGet, undecodable
    }

    /// The route `url` names, for a request made with `method` (nil reads as GET, as `URLRequest` defaults).
    public static func route(_ url: URL?, method: String?) -> Route {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .refused(.undecodable)
        }
        guard parts.scheme?.lowercased() == scheme else { return .refused(.notThisScheme) }
        // Exactly `d`: the core writes it so, and a URL Standard host of a non-special scheme keeps its case.
        guard parts.percentEncodedHost == authority else { return .refused(.notThisAuthority) }
        guard parts.percentEncodedUser == nil, parts.percentEncodedPassword == nil, parts.port == nil else {
            return .refused(.credentialsOrPort)
        }
        guard (method ?? "GET").uppercased() == "GET" else { return .refused(.notGet) }
        let path = parts.percentEncodedPath
        guard path.hasPrefix("/") else { return .refused(.unknownRoute) }
        let route = String(path.dropFirst())
        let query = parts.percentEncodedQuery.map { "?" + $0 } ?? ""
        if route.hasPrefix("entry/") {
            return route.count > "entry/".count ? .document(url) : .refused(.emptyPath)
        }
        for (prefix, make) in [("r/", Route.resource(path:)), ("sound/", Route.sound(path:))] where route.hasPrefix(prefix) {
            let rest = String(route.dropFirst(prefix.count)) + query
            return rest.isEmpty ? .refused(.emptyPath) : make(rest)
        }
        if route.hasPrefix("blocked/") {
            let rest = String(route.dropFirst("blocked/".count)) + query
            guard !rest.isEmpty else { return .refused(.emptyPath) }
            guard let remote = rest.removingPercentEncoding else { return .refused(.undecodable) }
            return .blocked(remote: remote)
        }
        return .refused(.unknownRoute)
    }

    /// The URL the view loads a document of this binding under: the entry's key under `entry/`, encoded as the core
    /// encodes a path segment, so that `#fragment` links resolve against it as the same document.
    public static func documentURL(for reference: EntryReference) -> URL? {
        // RFC 3986's unreserved characters, ASCII only: `CharacterSet.alphanumerics` would pass other scripts' letters.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let key = reference.key.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let occurrence = reference.occurrence == 0 ? "" : "?occurrence=\(reference.occurrence)"
        return URL(string: base + "entry/" + key + occurrence)
    }

    /// Whether `url` is within the view's own space: `xdict://d/` with no credentials or port.
    public static func isOwn(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == scheme && parts.percentEncodedHost == authority
            && parts.percentEncodedUser == nil && parts.percentEncodedPassword == nil && parts.port == nil
    }
}

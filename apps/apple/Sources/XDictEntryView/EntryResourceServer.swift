import Foundation
import XDictTokens

/// **What the scheme handler answers, decided apart from WebKit** so every rule is a unit test: one bound dictionary,
/// the one document the view is showing, and for every request either an answer or a refusal.
///
/// - Every answer carries the document's policy as a `Content-Security-Policy` header — entries, HTML and SVG
///   resources, scripts, images, everything (ADR-0009 decision 7: a shell-written `<meta>` missed an SVG document
///   navigated to under `r/`, spike 3 run 02). With no document yet there is no policy, and nothing is answered.
/// - **Nothing is ever redirected**: no 3xx, no `Location`, no `Refresh` (a resource that redirects loses CSP's path
///   restriction, ADR-0007 decision 14). No `Content-Disposition` either: nothing is answered as an attachment.
/// - `entry/…` serves only the document the view is loading; any other entry URL is a link, which the navigation
///   policy routes, and never a page.
/// - `blocked/…` is answered with a picture naming the remote host, never fetched (the owner's decision, ADR-0009).
@MainActor
public final class EntryResourceServer {
    /// The answer to one request.
    public struct Answer: Equatable, Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
    }

    public enum Serving: Equatable, Sendable {
        case answer(Answer)
        case refuse(String)
    }

    /// A rendered body (a page, a stylesheet, a script, an SVG document) is held to the reader's view ceiling, the
    /// contract's 16 MiB (`Limits.maxBodyBytes`); anything else to the core's 64 MiB (`Limits.maxResourceBytes`).
    nonisolated public static let maxRenderedBytes = 16 << 20
    nonisolated public static let maxResourceBytes = 64 << 20
    nonisolated static let rendered: Set<String> = ["text/html", "text/css", "text/javascript", "image/svg+xml"]

    public let content: any EntryContent
    /// Whether the policy header is sent: always, except in the development lab's isolated control for that layer.
    let attachesPolicy: Bool
    /// The words on a blocked image's placeholder, given the host: the view layer's sentence.
    let placeholderLabel: @MainActor (String) -> String

    private(set) var document: (url: URL, document: EntryDocument)?

    /// The folder XDict's phonetic faces are read from (`EntryFonts.bundled`); none, and `font/…` is refused.
    let fonts: URL?

    public init(content: any EntryContent, attachesPolicy: Bool = true, fonts: URL? = EntryFonts.bundled,
                placeholderLabel: @escaping @MainActor (String) -> String) {
        self.content = content
        self.attachesPolicy = attachesPolicy
        self.fonts = fonts
        self.placeholderLabel = placeholderLabel
    }

    /// The document the view is about to load under `url`. Replaces the one before: a binding shows one at a time.
    public func register(_ document: EntryDocument, at url: URL) {
        self.document = (url, document)
    }

    /// The answer to a request, asked of the bound dictionary where it must be.
    public func serve(_ request: URLRequest) async -> Serving {
        guard let (documentURL, current) = document else { return .refuse("no document, so no policy to send") }
        let policy = current.policy
        guard !policy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refuse("the document came with an empty policy")
        }
        switch EntryRoutes.route(request.url, method: request.httpMethod) {
        case .refused(let why):
            return .refuse("route: \(why.rawValue)")
        case .document(let url):
            guard url.absoluteString == documentURL.absoluteString else {
                return .refuse("an entry URL that is not the document being shown")
            }
            return answer(200, mime: "text/html; charset=utf-8", body: current.html, policy: policy,
                          ceiling: Self.maxRenderedBytes)
        case .resource(let path), .sound(let path):
            let found: EntryResource
            do {
                found = try await content.resource(path)
            } catch {
                return .refuse("the dictionary did not answer: \(error)")
            }
            switch found {
            case .missing:
                return answer(404, mime: "text/plain; charset=utf-8", body: Data(), policy: policy, ceiling: 0)
            case .found(let mime, let bytes):
                let type = Self.sanitized(mime)
                let ceiling = Self.rendered.contains(type) ? Self.maxRenderedBytes : Self.maxResourceBytes
                return answer(200, mime: type, body: bytes, policy: policy, ceiling: ceiling)
            }
        case .font(let file):
            // Read-only, from the app's own bundle; the route has already held the name to the eight files.
            guard let fonts, let bytes = try? Data(contentsOf: fonts.appending(path: file)) else {
                return .refuse("XDict's font \(file) is not in the bundle")
            }
            return answer(200, mime: "font/ttf", body: bytes, policy: policy, ceiling: Self.maxResourceBytes)
        case .blocked(let remote):
            let host = URLComponents(string: remote)?.host ?? ""
            let svg = Self.placeholder(label: placeholderLabel(host.isEmpty ? remote : host))
            return answer(200, mime: "image/svg+xml", body: svg, policy: policy, ceiling: Self.maxRenderedBytes)
        }
    }

    private func answer(_ status: Int, mime: String, body: Data, policy: String, ceiling: Int) -> Serving {
        guard body.count <= ceiling else {
            return .refuse("\(body.count) bytes of \(mime), more than \(ceiling)")
        }
        var headers = [
            "Content-Type": mime,
            "Content-Length": String(body.count),
            "Cache-Control": "no-store",
            // A script or stylesheet must be served as one: an `.mp3` named in `<script src>` is not run.
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
        ]
        if attachesPolicy { headers["Content-Security-Policy"] = policy }
        return .answer(Answer(status: status, headers: headers, body: body))
    }

    /// A MIME type as the core named it, or `application/octet-stream` when it is not one (`type/subtype` of token
    /// characters): a header value is never built from arbitrary text.
    nonisolated static func sanitized(_ mime: String) -> String {
        let token = /[A-Za-z0-9!#$&^_.+-]+/
        let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ (try? token.wholeMatch(in: $0)) != nil }) else {
            return "application/octet-stream"
        }
        return mime.lowercased()
    }

    /// The picture a blocked image becomes: its host, written by the shell, never fetched. Text is escaped for XML.
    nonisolated static func placeholder(label: String) -> Data {
        let escaped = label.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        typealias Box = Tokens.Placeholder
        typealias Words = Tokens.EntryText
        let width = min(max(Box.minWidth, CGFloat(escaped.count) * Box.charWidth + Box.padding), Box.maxWidth)
        func px(_ value: CGFloat) -> String { value == value.rounded() ? String(Int(value)) : String(describing: value) }
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(px(width))" height="\(px(Box.height))" role="img" \
            aria-label="\(escaped)"><rect x="\(px(Box.edge))" y="\(px(Box.edge))" width="\(px(width - 2 * Box.edge))" \
            height="\(px(Box.height - 2 * Box.edge))" rx="\(px(Box.radius))" fill="\(Words.placeholderFill)" \
            stroke="\(Words.placeholderStroke)" stroke-dasharray="\(Words.placeholderDash)"/><text x="\(px(Box.textX))" \
            y="\(px(Box.textBaseline))" font-family="\(Words.placeholderFont)" font-size="\(px(Box.fontSize))" \
            fill="\(Words.placeholderText)">\(escaped)</text></svg>
            """
        return Data(svg.utf8)
    }
}

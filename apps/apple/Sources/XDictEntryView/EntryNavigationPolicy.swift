import Foundation

/// **Which navigations an entry may make, decided before anything is sent** (ADR-0007 decision 14; ADR-0009 decision 7).
/// The navigation delegate sits outside the page, so the entry's scripts cannot undo it, and it sees what CSP does not
/// govern: meta refresh, `location=`, top navigation from a `srcdoc` frame, links SMIL animated, form submissions, and
/// the requests for new windows (spike 3, "What the navigation delegate sees").
///
/// The table, in order:
/// 1. A download, of any URL: refused.
/// 2. `about:blank` and `about:srcdoc` (frames the page writes itself, which inherit its policy): allowed.
/// 3. The document the view itself is loading, in the main frame: allowed, once. One it asked for and has since
///    replaced with another, in the main frame: cancelled, and nothing more — WebKit still asks about a replaced load,
///    and that question is the view's own, not the page following a link to the entry (`EntryDocumentLoads`).
/// 4. The shown document's own URL with a fragment, in the main frame: allowed (WebKit scrolls; nothing is fetched).
/// 5. Anything else under `xdict://d/`: cancelled and **routed** — the core says what it means (a lookup, a sound, a
///    remote link it blocked) and the view acts on that. Never loaded as a page, in any frame.
/// 6. A remote URL (`http`, `https`, `ws`, `wss`, `ftp`) a link activation asked for: cancelled, and the reader is
///    **asked** whether to open it in their browser (the owner's decision, 2026-10-14). Any other way to a remote URL:
///    refused.
/// 7. Every other scheme (`data:`, `blob:`, `javascript:`, `file:`, `mailto:`…): refused.
public enum EntryNavigationPolicy {
    public enum Kind: Int, Sendable {
        case linkActivated = 0, formSubmitted = 1, backForward = 2, reload = 3, formResubmitted = 4, other = -1
    }

    /// What WebKit says about one navigation action.
    public struct Facts: Sendable {
        public let url: URL?
        /// nil when WebKit asks for a new window (`targetFrame == nil`).
        public let targetIsMainFrame: Bool?
        public let kind: Kind
        public let download: Bool
        public let ownLoad: OwnLoad?
        public let currentDocument: URL?

        public init(url: URL?, targetIsMainFrame: Bool?, kind: Kind, download: Bool, ownLoad: OwnLoad?,
                    currentDocument: URL?) {
            self.url = url
            self.targetIsMainFrame = targetIsMainFrame
            self.kind = kind
            self.download = download
            self.ownLoad = ownLoad
            self.currentDocument = currentDocument
        }
    }

    /// Which of the view's own loads a main-frame navigation is: the last one asked for, or one asked for before it.
    public enum OwnLoad: Sendable {
        case latest, superseded
    }

    public enum Verdict: Equatable, Sendable {
        /// Load the document the view asked for.
        case loadDocument
        /// Cancel a load the view asked for and has since replaced; nothing else.
        case dropSuperseded
        case allowFrameOfItsOwn
        case allowSameDocument
        /// Cancel; ask the core what the URL means and act on that.
        case route(String)
        /// Cancel; ask the reader whether to open it in their browser.
        case askReader(URL)
        case refuse(Refusal)

        public var allows: Bool {
            switch self {
            case .loadDocument, .allowFrameOfItsOwn, .allowSameDocument: true
            case .dropSuperseded, .route, .askReader, .refuse: false
            }
        }
    }

    public enum Refusal: String, Sendable {
        case download, noURL, remoteNotActivatedByALink, otherScheme
    }

    static let remoteSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp"]

    public static func decide(_ facts: Facts) -> Verdict {
        guard !facts.download else { return .refuse(.download) }
        guard let url = facts.url else { return .refuse(.noURL) }
        let text = url.absoluteString
        if text == "about:blank" || text == "about:srcdoc" { return .allowFrameOfItsOwn }
        let scheme = url.scheme?.lowercased() ?? ""
        if EntryRoutes.isOwn(url) {
            if facts.targetIsMainFrame == true {
                switch facts.ownLoad {
                case .latest: return .loadDocument
                case .superseded: return .dropSuperseded
                case nil: break
                }
                if let current = facts.currentDocument, url.fragment != nil, sameDocument(url, current) {
                    return .allowSameDocument
                }
            }
            return .route(text)
        }
        if remoteSchemes.contains(scheme) {
            return facts.kind == .linkActivated ? .askReader(url) : .refuse(.remoteNotActivatedByALink)
        }
        return .refuse(.otherScheme)
    }

    /// Whether a navigation response may be shown: only the view's own space and the frames a page writes itself, and
    /// only a type WebKit can show (anything else would become a download).
    public static func responseAllowed(url: URL?, canShowMIMEType: Bool) -> Bool {
        guard canShowMIMEType, let url else { return false }
        let text = url.absoluteString
        return EntryRoutes.isOwn(url) || text == "about:blank" || text == "about:srcdoc"
    }

    /// `a` and `b` name one document: equal but for the fragment.
    static func sameDocument(_ a: URL, _ b: URL) -> Bool {
        func stripped(_ url: URL) -> String? {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            return parts.string
        }
        guard let left = stripped(a), let right = stripped(b) else { return false }
        return left == right
    }
}

/// **The documents the view asked WebKit to load whose navigation WebKit has not yet asked about**, in the order asked.
/// WebKit asks about each load once and in order, even about one a later load has already replaced (a reader moving
/// through the results faster than WebKit answers): that question is the view's own replaced load, and must be dropped,
/// not routed as the page going to that entry's URL — which is also a link to its word (the E2E `lookup` stage saw the
/// replaced `apple` looked up in link mode, 2026-10-15).
struct EntryDocumentLoads {
    private var asked: [URL] = []

    mutating func load(_ url: URL) {
        asked.append(url)
    }

    /// Whether a main-frame navigation to `url` is one of the view's loads: the last one asked (to show), one asked
    /// before it (replaced), or none (the page's own).
    func status(of url: URL) -> EntryNavigationPolicy.OwnLoad? {
        guard let index = asked.firstIndex(where: { $0.absoluteString == url.absoluteString }) else { return nil }
        return index == asked.count - 1 ? .latest : .superseded
    }

    /// WebKit asked about the load of `url`: it, and any load asked before it that WebKit never asked about, are done.
    mutating func answered(_ url: URL) {
        guard let index = asked.firstIndex(where: { $0.absoluteString == url.absoluteString }) else { return }
        asked.removeFirst(index + 1)
    }
}

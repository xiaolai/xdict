import AppKit
import WebKit

/// What a pane asks of the view that owns it.
@MainActor
protocol EntryPaneHost: AnyObject {
    func record(_ event: EntryEvent)
    /// A link the core classified, for the window or the speech layer.
    func perform(_ action: EntryLinkAction, from pane: EntryPane)
    /// A remote URL the reader (or a script) activated: ask the reader.
    func askReader(_ url: URL, from pane: EntryPane)
    /// A new window, asked for only when the confinement allows one (the lab's control for that layer, never the app).
    func newWindow(_ configuration: WKWebViewConfiguration, for action: WKNavigationAction) -> WKWebView?
    func documentFinished(_ pane: EntryPane)
}

/// Find's answer: the matches the reader can step through, those in folded sections, and which one is current (1-based,
/// 0 when none).
public struct EntryFindResult: Equatable, Sendable {
    public let visible: Int
    public let hidden: Int
    public let current: Int
}

/// **One web view, bound to one open dictionary for its whole life** (`EntryBinding`; ADR-0009 refutation, item 13), with
/// every confinement layer of ADR-0009 decision 7 in place before its first byte: its own non-persistent data store,
/// its own scheme handler answering from this dictionary alone, the policy header, the rule list, the navigation and UI
/// delegates, and the two WebKit switches read back off on the preferences it is made with.
@MainActor
final class EntryPane: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// The shell's own scripts run here; the page cannot reach them.
    static let world = WKContentWorld.world(name: "xdict-entry")

    let binding: EntryBinding
    let webView: EntryWebView
    let switchesReadBack: [String: Bool]
    private let content: any EntryContent
    private let server: EntryResourceServer
    private let handler: EntrySchemeHandler
    private let confinement: EntryConfinement
    private weak var host: EntryPaneHost?
    private(set) var reference: EntryReference?
    /// Where the document being loaded lands once it has: applied once, at its `didFinish`.
    private var landing: EntryLanding = .top
    /// The documents asked of WebKit whose navigation it has not yet asked about.
    private var loads = EntryDocumentLoads()
    private(set) var current: URL?
    private var generation = 0
    private var scheme: EntryColourScheme
    private var frame: EntryReadingFrame
    private var restartedAfterCrash = false
    private(set) var closed = false

    /// **Everything that must hold before a web view exists**, checked in order; nothing is made unless all of it does.
    static func gate(_ confinement: EntryConfinement, switches: any WebKitFeatureSwitches,
                     ruleList: Result<WKContentRuleList, EntryRefusal>?) -> Result<[String: Bool], EntryRefusal> {
        if confinement.ruleList {
            switch ruleList {
            case .success: break
            case .failure(let why): return .failure(why)
            case nil: return .failure(.ruleListUnavailable("the rule list was not compiled"))
            }
        }
        guard !confinement.featuresOff.isEmpty else { return .success([:]) }
        return EntrySwitches.turnOff(confinement.featuresOff, on: switches)
    }

    /// The preferences every pane's web view is made with: a script opens no window by itself (part of the new-window
    /// layer; off only in the lab's control for that layer), no element goes full screen, and Tab moves through the
    /// entry's links so the keyboard can follow one (R10).
    static func configure(_ preferences: WKPreferences, confinement: EntryConfinement) {
        preferences.javaScriptCanOpenWindowsAutomatically = !confinement.refusesNewWindows
        preferences.isElementFullscreenEnabled = false
        preferences.tabFocusesLinks = true
    }

    /// A pane for `content`, or the reason none is made. `makeWebView` is called only once the gate has passed, so a
    /// refusal leaves no web view, and nothing can load.
    static func open(content: any EntryContent, confinement: EntryConfinement, scheme: EntryColourScheme,
                     frame: EntryReadingFrame = .all,
                     ruleList: Result<WKContentRuleList, EntryRefusal>?,
                     switches: @MainActor (WKPreferences) -> any WebKitFeatureSwitches, host: EntryPaneHost,
                     makeWebView: (WKWebViewConfiguration) -> EntryWebView = { EntryWebView(frame: .zero, configuration: $0) })
        -> Result<EntryPane, EntryRefusal> {
        let preferences = WKPreferences()
        let readBack: [String: Bool]
        switch gate(confinement, switches: switches(preferences), ruleList: ruleList) {
        case .failure(let why): return .failure(why)
        case .success(let values): readBack = values
        }
        let server = EntryResourceServer(content: content, attachesPolicy: confinement.policyHeader) { remoteHost in
            String(localized: EntrySentences.remoteImage(host: remoteHost))
        }
        let handler = EntrySchemeHandler(server: server) { [weak host] event in host?.record(event) }
        let configuration = WKWebViewConfiguration()
        configuration.preferences = preferences
        configure(preferences, confinement: confinement)
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: EntryRoutes.scheme)
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        let controller = WKUserContentController()
        if confinement.ruleList, case .success(let list) = ruleList { controller.add(list) }
        configuration.userContentController = controller
        let pane = EntryPane(content: content, webView: makeWebView(configuration), server: server, handler: handler,
                             confinement: confinement, scheme: scheme, frame: frame, host: host, readBack: readBack)
        // The one message handler, in the shell's world: the page's world has none to call. Removed in `close`, which
        // breaks the cycle it makes (controller → pane → web view → controller).
        controller.add(pane, contentWorld: world, name: EntryScripts.handlerName)
        return .success(pane)
    }

    private init(content: any EntryContent, webView: EntryWebView, server: EntryResourceServer,
                 handler: EntrySchemeHandler, confinement: EntryConfinement, scheme: EntryColourScheme,
                 frame: EntryReadingFrame, host: EntryPaneHost, readBack: [String: Bool]) {
        self.binding = content.binding
        self.content = content
        self.webView = webView
        self.server = server
        self.handler = handler
        self.confinement = confinement
        self.scheme = scheme
        self.frame = frame
        self.host = host
        self.switchesReadBack = readBack
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.onMenu = { [weak self] kept, removed in self?.host?.record(.menuFiltered(kept: kept, removed: removed)) }
        installScripts()
        applyScheme()
    }

    /// The web view the reader sees.
    var view: EntryWebView { webView }

    // MARK: - Showing

    /// Asks the dictionary for the entry, then loads it, to land at `landing`. A later `show` supersedes an earlier one
    /// still waiting.
    func show(_ reference: EntryReference, landing: EntryLanding = .top) async -> Bool {
        generation += 1
        let mine = generation
        host?.record(.documentRequested(reference))
        let document: EntryDocument
        do {
            document = try await content.entry(reference)
        } catch {
            host?.record(.documentFailed(reference, String(describing: error)))
            return false
        }
        guard mine == generation, !closed else { return false }
        guard !document.policy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            host?.record(.refusedToRender(.noPolicy))
            return false
        }
        guard let url = EntryRoutes.documentURL(for: reference) else {
            host?.record(.documentFailed(reference, "no URL can name this key"))
            return false
        }
        server.register(document, at: url)
        self.reference = reference
        self.landing = landing
        load(url)
        return true
    }

    private func load(_ url: URL) {
        loads.load(url)
        installScripts()
        view.load(URLRequest(url: url))
    }

    /// The shown document again, from memory (a new appearance, or after WebKit's content process ended).
    func reloadDocument() {
        guard let current, !closed else { return }
        load(current)
    }

    func close() {
        guard !closed else { return }
        closed = true
        handler.close()
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.onMenu = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.removeFromSuperview()
    }

    // MARK: - Reading

    func setZoom(_ zoom: Double) {
        view.pageZoom = zoom
    }

    func setFrame(_ frame: EntryReadingFrame) {
        guard frame != self.frame else { return }
        let restyled = Self.restyles(from: self.frame, to: frame)
        self.frame = frame
        // "Original style" is the core's rendering too, not only the frame: the entry is asked for again, not reloaded
        // from memory (it was: the frame changed and the reading style's markup stayed, E2E 2026-10-16).
        if restyled, let reference {
            Task { _ = await show(reference) }
        } else {
            reloadDocument()
        }
    }

    /// Whether going from one frame to another changes which rendering the core gives (ADR-0010 Q3).
    nonisolated static func restyles(from old: EntryReadingFrame, to new: EntryReadingFrame) -> Bool {
        old.contains(.minimal) != new.contains(.minimal)
    }

    func setScheme(_ scheme: EntryColourScheme) {
        guard scheme != self.scheme else { return }
        self.scheme = scheme
        applyScheme()
        reloadDocument()
    }

    private func applyScheme() {
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.underPageBackgroundColor = scheme == .dark ? NSColor(white: 30 / 255, alpha: 1) : .white
    }

    private func installScripts() {
        let controller = view.configuration.userContentController
        controller.removeAllUserScripts()
        for source in EntryScripts.installed(scheme, frame: frame) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: Self.world))
        }
    }

    func find(_ query: String) async -> EntryFindResult? {
        await callFind("return window.__xdictFind.find(q)", ["q": query])
    }

    func findStep(forward: Bool) async -> EntryFindResult? {
        await callFind("return window.__xdictFind.step(f)", ["f": forward])
    }

    func clearFind() async {
        _ = await callFind("return window.__xdictFind.clear()", [:])
    }

    private func callFind(_ body: String, _ arguments: [String: Any]) async -> EntryFindResult? {
        guard !closed, let answer = try? await view.callAsyncJavaScript(body, arguments: arguments, in: nil,
                                                                         contentWorld: Self.world),
              let object = answer as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        return EntryFindResult(visible: int("visible"), hidden: int("hidden"), current: int("current"))
    }

    private func scroll(to anchor: String) {
        Task { @MainActor in await land(.anchor(anchor)) }
    }

    /// Scrolls to `landing`; answers where the document now is.
    @discardableResult
    func land(_ landing: EntryLanding) async -> Double? {
        guard !closed, let script = EntryScripts.landing(landing) else { return nil }
        return (try? await view.callAsyncJavaScript(script.body, arguments: script.arguments, in: nil,
                                                    contentWorld: Self.world)) as? Double
    }

    /// How far down the entry the reader has scrolled, in CSS pixels; nil with no document.
    /// Opens (or closes) every fold of the entry the way a reader's click would; how many heads were clicked.
    func expandAll(_ open: Bool) async -> Int {
        guard !closed, current != nil else { return 0 }
        let answer = try? await view.callAsyncJavaScript(
            "return window.__xdictDisclosure ? window.__xdictDisclosure.expand(o) : 0", arguments: ["o": open], in: nil,
            contentWorld: Self.world)
        return (answer as? NSNumber)?.intValue ?? 0
    }

    func scrollOffset() async -> Double? {
        guard !closed, current != nil else { return nil }
        return (try? await view.callAsyncJavaScript(EntryScripts.scrollOffset, arguments: [:], in: nil,
                                                    contentWorld: Self.world)) as? Double
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let kind = EntryNavigationPolicy.Kind(rawValue: action.navigationType.rawValue) ?? .other
        let url = action.request.url
        // Only a main-frame navigation can be a load the view asked for.
        let own = action.targetFrame?.isMainFrame == true ? url.flatMap(loads.status(of:)) : nil
        let facts = EntryNavigationPolicy.Facts(
            url: url, targetIsMainFrame: action.targetFrame?.isMainFrame, kind: kind,
            download: action.shouldPerformDownload, ownLoad: own, currentDocument: current)
        let verdict = EntryNavigationPolicy.decide(facts)
        host?.record(.navigation(url: url?.absoluteString ?? "", verdict: String(describing: verdict),
                                 mainFrame: action.targetFrame?.isMainFrame ?? false, type: kind.rawValue))
        if let url, verdict == .loadDocument || verdict == .dropSuperseded { loads.answered(url) }
        guard confinement.navigationPolicy else {
            if case .loadDocument = verdict { current = url }
            decisionHandler(.allow)
            return
        }
        switch verdict {
        case .loadDocument:
            current = url
            decisionHandler(.allow)
        case .dropSuperseded:
            decisionHandler(.cancel)
        case .allowFrameOfItsOwn, .allowSameDocument:
            decisionHandler(.allow)
        case .route(let url):
            decisionHandler(.cancel)
            route(url, activatedByALink: kind == .linkActivated)
        case .askReader(let url):
            decisionHandler(.cancel)
            host?.askReader(url, from: self)
        case .refuse:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let allowed = EntryNavigationPolicy.responseAllowed(url: response.response.url,
                                                            canShowMIMEType: response.canShowMIMEType)
        if !allowed { host?.record(.navigationResponseRefused(url: response.response.url?.absoluteString ?? "")) }
        decisionHandler(allowed || !confinement.navigationPolicy ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard let url = webView.url, let current, EntryNavigationPolicy.sameDocument(url, current) else { return }
        let arrival = landing
        landing = .top
        Task { @MainActor in
            // Landed before the document is reported finished, so whoever waits for it finds it where it belongs.
            await land(arrival)
            host?.record(.documentFinished(url))
            host?.documentFinished(self)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        host?.record(.contentProcessTerminated)
        guard !restartedAfterCrash else { return }
        restartedAfterCrash = true
        reloadDocument()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        host?.record(.downloadRefused(url: navigationAction.request.url?.absoluteString ?? ""))
        download.cancel { _ in }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        host?.record(.downloadRefused(url: navigationResponse.response.url?.absoluteString ?? ""))
        download.cancel { _ in }
    }

    private func route(_ url: String, activatedByALink: Bool) {
        guard let reference else { return }
        Task { @MainActor in
            let link: EntryLink
            do {
                link = try await content.link(url, origin: .entry(reference))
            } catch {
                host?.record(.linkRouted(url: url, action: "unanswered: \(error)"))
                return
            }
            let action = EntryLinkAction.for(link, activatedByALink: activatedByALink)
            host?.record(.linkRouted(url: url, action: action.name))
            guard !closed else { return }
            switch action {
            case .scroll(let anchor): scroll(to: anchor)
            case .askReader(let remote): host?.askReader(remote, from: self)
            case .nothing: break
            case .lookup, .sound, .speak: host?.perform(action, from: self)
            }
        }
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        host?.record(.popupRefused(url: navigationAction.request.url?.absoluteString ?? ""))
        guard !confinement.refusesNewWindows else { return nil }
        return host?.newWindow(configuration, for: navigationAction)
    }

    // MARK: - WKScriptMessageHandler (the shell's world only)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world == Self.world, let body = message.body as? [String: Any],
              body["kind"] as? String == "blocked-image", let text = body["url"] as? String,
              case .blocked(let remote) = EntryRoutes.route(URL(string: text), method: "GET") else { return }
        guard let url = RemoteOpenGate.openable(remote) else {
            host?.record(.linkRouted(url: text, action: "nothing"))
            return
        }
        host?.askReader(url, from: self)
    }
}

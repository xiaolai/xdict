import AppKit
import WebKit
import XDictTokens

/// What a pane asks of the view that owns it.
@MainActor
protocol EntryPaneHost: AnyObject {
    func record(_ event: EntryEvent)
    /// A link the core classified, for the window or the speech layer.
    func perform(_ action: EntryLinkAction, from pane: EntryPane)
    /// A remote URL the reader (or a script) activated: ask the reader.
    func askReader(_ url: URL, from pane: EntryPane)
    /// A word the reader ⌘-clicked, to open in a new tab (parity P47).
    func openInNewTab(_ click: EntryWordClick, from pane: EntryPane)
    /// A sense the reader clicked (plan-explain-sense WI-5): its ordinal, and this frame's entry for the window to
    /// name it in the dictionary it was clicked in.
    func selectSense(_ click: EntrySenseClick, from pane: EntryPane)
    /// Whether this pane draws the entry the presentation is about: a page's panes finish one by one, and the other
    /// panes' finishes are not the entry's (audit round 4, 2026-10-26).
    func isPrimary(_ pane: EntryPane) -> Bool
    /// A new window, asked for only when the confinement allows one (the lab's control for that layer, never the app).
    func newWindow(_ configuration: WKWebViewConfiguration, for action: WKNavigationAction) -> WKWebView?
    func documentFinished(_ pane: EntryPane)
    /// The value the page's root is given for each option the pane's edition declares (ADR-0013 d.4).
    func displayValues(_ options: EntryDisplayOptions, for pane: EntryPane) -> [EntryDisplayValue]
    /// The shown document holds new display values: what was found in it may have changed.
    func displayApplied(_ pane: EntryPane)
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
    /// **Told when a load failed after `show` answered yes** (audit 2026-10-29): WebKit's failure is the only word that a
    /// document will never arrive, and without it a frame said "Loading…" for as long as it stayed on screen.
    var onLoadFailed: ((EntryReference) -> Void)?

    /// The language this pane's content is written in, as the content declares it.
    var contentLanguage: String? { content.language }

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
    /// **The reference of the document that is shown**, paired with `current` when its navigation is allowed — never the
    /// newer `reference` a `show` has already set (plan-explain-sense WI-5): in the gap between the two the old document
    /// still runs, and a click from it must be read against the old entry.
    private(set) var documentReference: EntryReference?
    private var generation = 0
    private(set) var scheme: EntryColourScheme
    private var frame: EntryReadingFrame
    private let style: EntryStyle
    /// **The reader's Chinese face** (owner, 2026-10-29): `--xdict-font-cjk` on this pane's document, set at document start
    /// and again whenever the reader chooses another.
    private(set) var chineseFace: EntryChineseFace
    private var restartedAfterCrash = false
    private(set) var closed = false
    /// What the bound edition declares (ADR-0013), asked once for the pane's life, before its first document.
    private var displayAsk: Task<EntryDisplayOptions, Never>?
    private var displayKnown = false
    private(set) var display: EntryDisplayOptions = .none
    /// The values the page's root is given, the default included: in the scripts every load starts with.
    private(set) var displayValues: [EntryDisplayValue] = []

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
                     frame: EntryReadingFrame = .all, style: EntryStyle = .bundled,
                     chineseFace: EntryChineseFace = .songti,
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
                             confinement: confinement, scheme: scheme, frame: frame, style: style,
                             chineseFace: chineseFace, host: host, readBack: readBack)
        // The one message handler, in the shell's world: the page's world has none to call. Removed in `close`, which
        // breaks the cycle it makes (controller → pane → web view → controller).
        controller.add(pane, contentWorld: world, name: EntryScripts.handlerName)
        return .success(pane)
    }

    private init(content: any EntryContent, webView: EntryWebView, server: EntryResourceServer,
                 handler: EntrySchemeHandler, confinement: EntryConfinement, scheme: EntryColourScheme,
                 frame: EntryReadingFrame, style: EntryStyle, chineseFace: EntryChineseFace,
                 host: EntryPaneHost, readBack: [String: Bool]) {
        self.chineseFace = chineseFace
        self.binding = content.binding
        self.content = content
        self.webView = webView
        self.server = server
        self.handler = handler
        self.confinement = confinement
        self.scheme = scheme
        self.frame = frame
        self.style = style
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
        await askDisplayOptions()
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

    /// Asks the bound edition's display options, once; every later call waits for that one answer. A failure is
    /// recorded and the entry shown as the dictionary wrote it (no CSS, no attribute), never refused for it.
    private func askDisplayOptions() async {
        guard !displayKnown else { return }
        let ask = displayAsk ?? Task { @MainActor [content, weak host] in
            do {
                return try await content.displayOptions()
            } catch {
                host?.record(.displayOptionsFailed(String(describing: error)))
                return EntryDisplayOptions.none
            }
        }
        displayAsk = ask
        let options = await ask.value
        guard !displayKnown, !closed else { return }
        displayKnown = true
        display = options
        displayValues = host?.displayValues(options, for: self) ?? []
    }

    /// **The reader changed a display option** (ADR-0013 d.3): every later load starts with `values`, and the shown
    /// document is given them in place, from the shell's world, without being asked for or loaded again. False when
    /// nothing changed.
    @discardableResult
    func setDisplayValues(_ values: [EntryDisplayValue]) -> Bool {
        guard values != displayValues, !closed else { return false }
        displayValues = values
        installScripts()
        host?.record(.displayApplied(values.map { "\($0.attribute)=\($0.value)" }))
        guard current != nil else { return true }
        let arguments: [String: Any] = ["v": values.map { [$0.attribute, $0.value] }]
        Task { @MainActor in
            _ = try? await view.callAsyncJavaScript(EntryScripts.setDisplay, arguments: arguments, in: nil,
                                                    contentWorld: Self.world)
            guard !closed else { return }
            host?.displayApplied(self)
        }
        return true
    }

    /// **The document now shown is the one this navigation loads**, with the reference it was asked for: the pair is
    /// written together, so no reader of one can see the other's newer value.
    private func documentShown(_ url: URL?) {
        current = url
        documentReference = reference
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
        applyScheme()
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

    /// The reader chose another Chinese face: the scripts are reinstalled and the document reloaded, so the new
    /// `--xdict-font-cjk` is on the root before the style is applied.
    func setChineseFace(_ face: EntryChineseFace) {
        guard face != chineseFace else { return }
        chineseFace = face
        installScripts()
        reloadDocument()
    }

    func setScheme(_ scheme: EntryColourScheme) {
        guard scheme != self.scheme else { return }
        self.scheme = scheme
        applyScheme()
        reloadDocument()
    }

    /// What the web view draws under the page: the theme's paper, except in the lookup popover (P41), where the entry
    /// sits on the popover's glass, as Apple's does. "Original style" drops the panel layer, so it keeps its paper.
    struct Page: Equatable {
        let draws: Bool
        let under: NSColor
    }

    static func page(_ scheme: EntryColourScheme, frame: EntryReadingFrame) -> Page {
        if frame.contains(.panel) { return Page(draws: false, under: .clear) }
        return Page(draws: true, under: Tokens.Colour.entryPage.fixed(dark: scheme == .dark))
    }

    private func applyScheme() {
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let page = Self.page(scheme, frame: frame)
        view.underPageBackgroundColor = page.under
        // WKWebView has no public switch for its own background; `drawsBackground` is the key AppKit's web views take.
        view.setValue(page.draws, forKey: "drawsBackground")
    }

    private func installScripts() {
        let controller = view.configuration.userContentController
        controller.removeAllUserScripts()
        Self.install(EntryScripts.installed(scheme, frame: frame, style: style, display: display, values: displayValues,
                                            language: content.language,
                                            chineseFace: chineseFace),
                     into: controller)
    }

    /// The shell's scripts as every entry installs them: at document start, the main frame only, in the shell's world.
    static func install(_ sources: [String], into controller: WKUserContentController) {
        for source in sources {
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

    /// **The chosen sense marked in this frame, or the mark cleared** (HIG audit UI21): `sense-clicks.js` draws it.
    func markSense(_ id: UInt32?) async {
        guard !closed else { return }
        let argument: Any = id.map { NSNumber(value: $0) } ?? NSNull()
        _ = try? await view.callAsyncJavaScript("return window.__xdictSense ? window.__xdictSense.mark(i) : null",
                                                arguments: ["i": argument], in: nil, contentWorld: Self.world)
    }

    /// The ordinal one sense after (or before) the chosen one in this frame, or nil when it has none (UI22).
    func stepSense(_ delta: Int) async -> UInt32? {
        guard !closed, let answer = try? await view.callAsyncJavaScript(
            "return window.__xdictSense ? window.__xdictSense.step(d) : null", arguments: ["d": delta], in: nil,
            contentWorld: Self.world), let number = answer as? NSNumber else { return nil }
        // The same bounds as a click's message: the page's answer is untrusted.
        return EntrySenseClick(message: ["kind": "sense", "id": number])?.id
    }

    /// The entry's selected text, for Use Selection for Find.
    func selectedText() async -> String? {
        guard !closed else { return nil }
        return try? await view.callAsyncJavaScript("return window.__xdictFind.selection()", arguments: [:], in: nil,
                                                   contentWorld: Self.world) as? String
    }

    /// Scrolls the entry to its selection, for Jump to Selection.
    func jumpToSelection() async {
        guard !closed else { return }
        _ = try? await view.callAsyncJavaScript("return window.__xdictFind.jump()", arguments: [:], in: nil,
                                                contentWorld: Self.world)
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

    func documentHeight() async -> Double? {
        guard !closed, current != nil else { return nil }
        return (try? await view.callAsyncJavaScript(EntryScripts.documentHeight, arguments: [:], in: nil,
                                                    contentWorld: Self.world)) as? Double
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
            if case .loadDocument = verdict { documentShown(url) }
            decisionHandler(.allow)
            return
        }
        switch verdict {
        case .loadDocument:
            documentShown(url)
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
            host?.record(.documentFinished(url, primary: host?.isPrimary(self) ?? true))
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
        // The document the reader clicked in, not the one a newer `show` is already fetching.
        guard let reference = documentReference ?? reference else { return }
        let askedIn = generation
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
            // The pane may have moved to another document while the link was being resolved: the answer belongs to the
            // document it was asked from, never to the one showing now.
            // **A -> B -> A is two documents** (audit 2026-10-29, verification round 2): the reference alone cannot tell
            // them apart, so the generation the link was asked in must still be the pane's.
            guard !closed, documentReference == reference, generation == askedIn else { return }
            switch action {
            case .scroll(let anchor): scroll(to: anchor)
            case .askReader(let remote): host?.askReader(remote, from: self)
            case .nothing: break
            case .lookup, .sound, .speak: host?.perform(action, from: self)
            }
        }
    }

    /// A navigation that never became the document: refused by the network, the scheme handler or WebKit itself. A
    /// cancelled one is the `show` that superseded it, and says nothing about the document now asked for.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: Error) {
        guard !closed, (error as NSError).code != NSURLErrorCancelled, let reference else { return }
        host?.record(.documentFailed(reference, "navigation: \(error)"))
        onLoadFailed?(reference)
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        host?.record(.popupRefused(url: navigationAction.request.url?.absoluteString ?? ""))
        guard !confinement.refusesNewWindows else { return nil }
        return host?.newWindow(configuration, for: navigationAction)
    }

    // MARK: - WKScriptMessageHandler (the shell's world only)

    /// What a message to the handler is: only the shell's world is heard, and only in the shapes its scripts post.
    enum Message: Equatable {
        case blockedImage(String)
        case word(EntryWordClick)
        case sense(EntrySenseClick)
        case refused
    }

    /// **The same document, a fragment aside**: an in-page link leaves a fragment on the URL the frame reports, and the
    /// reader who followed it is still reading this entry. A different path, query or scheme is another document.
    nonisolated static func sameDocument(_ message: URL?, _ current: URL?) -> Bool {
        guard let message, let current else { return false }
        func bare(_ url: URL) -> String {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.fragment = nil
            return parts?.string ?? url.absoluteString
        }
        return bare(message) == bare(current)
    }

    nonisolated static func message(_ body: Any, fromShellsWorld: Bool) -> Message {
        guard fromShellsWorld, let object = body as? [String: Any] else { return .refused }
        switch object["kind"] as? String {
        case "blocked-image": return (object["url"] as? String).map(Message.blockedImage) ?? .refused
        case "word": return EntryWordClick(message: body).map(Message.word) ?? .refused
        case "sense": return EntrySenseClick(message: body).map(Message.sense) ?? .refused
        default: return .refused
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch Self.message(message.body, fromShellsWorld: message.world == Self.world) {
        case .refused:
            host?.record(.messageRefused)
        case .word(let click):
            host?.openInNewTab(click, from: self)
        case .sense(let click):
            // **A message from a document the pane has moved past is stale** (plan-explain-sense WI-5): the old
            // document can still run while the next one's navigation is being decided, and its ordinal would be read
            // against the new entry. The frame's own request says which document posted it; only the main frame's
            // counts, and a fragment an in-page link left does not make another document.
            guard message.frameInfo.isMainFrame,
                  Self.sameDocument(message.frameInfo.request.url, current) else {
                host?.record(.messageRefused)
                return
            }
            host?.selectSense(click, from: self)
        case .blockedImage(let text):
            guard case .blocked(let remote) = EntryRoutes.route(URL(string: text), method: "GET") else { return }
            guard let url = RemoteOpenGate.openable(remote) else {
                host?.record(.linkRouted(url: text, action: "nothing"))
                return
            }
            host?.askReader(url, from: self)
        }
    }
}

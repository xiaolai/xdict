import AppKit
import WebKit
import os
import XDictTokens

/// What the entry view is given: where preferences live, how a consented remote link is opened, the confinement (the
/// app passes `.production` and nothing else), where its rule list is compiled, and who listens to its events.
@MainActor
public struct EntryEnvironment {
    public var preferences: EntryPreferences
    public var opener: any EntryURLOpener
    public var confinement: EntryConfinement
    public var ruleListDirectory: URL
    /// The switches of a fresh `WKPreferences`: WebKit's own, unless the lab injects a fault to show refusal.
    public var switches: @MainActor (WKPreferences) -> any WebKitFeatureSwitches
    public var events: @MainActor (EntryEvent) -> Void
    /// A new window's web view, asked for only when `confinement.refusesNewWindows` is off (the lab's control).
    public var newWindow: (@MainActor (WKWebViewConfiguration, WKNavigationAction) -> WKWebView?)?
    /// The reading frame's layers (`EntryReadingFrame`): all of them in XDict; the lab's gallery turns them off to show
    /// the dictionary as it styles itself.
    public var readingFrame: EntryReadingFrame = .all
    /// The reading style's text (`EntryStyle`): `bundled` in XDict; only the lab's gallery gives another, read from its
    /// `--style-dir`, so a style edit reaches a picture without a rebuild.
    public var style: EntryStyle = .bundled

    public init(preferences: EntryPreferences = EntryPreferences(), opener: any EntryURLOpener = WorkspaceOpener(),
                confinement: EntryConfinement = .production,
                ruleListDirectory: URL = EntryEnvironment.defaultRuleListDirectory,
                switches: @escaping @MainActor (WKPreferences) -> any WebKitFeatureSwitches = { PreferencesSwitches($0) },
                events: @escaping @MainActor (EntryEvent) -> Void = { _ in },
                newWindow: (@MainActor (WKWebViewConfiguration, WKNavigationAction) -> WKWebView?)? = nil) {
        self.preferences = preferences
        self.opener = opener
        self.confinement = confinement
        self.ruleListDirectory = ruleListDirectory
        self.switches = switches
        self.events = events
        self.newWindow = newWindow
    }

    /// The app's Caches, which hold nothing that cannot be rebuilt.
    public static var defaultRuleListDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "EntryRuleList", directoryHint: .isDirectory)
    }
}

/// **The entry view**: one dictionary entry, confined (ADR-0009 decision 7), with find, zoom and appearance. The window
/// (WI-6) gives it an entry and a dictionary's `EntryContent`; it answers with lookups, sounds and spoken words, and asks
/// the reader before any remote link leaves.
///
/// Showing an entry of another dictionary replaces the web view (`EntryPane`), never reuses it (ADR-0009 refutation,
/// item 13). A refusal to render — a WebKit switch missing or still on, no rule list, no policy — shows its sentence in
/// place of the entry, and no web view is made.
@MainActor
public final class EntryViewController: NSViewController, EntryPaneHost {
    public var onLookup: ((_ query: String, _ anchor: String?) -> Void)?
    public var onSound: ((_ path: String) -> Void)?
    public var onSpeak: ((_ text: String) -> Void)?

    private var environment: EntryEnvironment
    private var pane: EntryPane?
    /// The All page (parity P15), while one is shown instead of a single entry: one frame, one pane, per dictionary.
    private var page: EntryPage?
    /// The page's dictionary whose entry the window counts as shown (its sidebar row).
    private var primaryItem: UUID?
    /// The frame a link, a sound or a spoken word last came from.
    private weak var activePane: EntryPane?
    private var ruleList: Result<WKContentRuleList, EntryRefusal>?
    private let gate = RemoteOpenGate()
    let container = NSView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let findBar = EntryFindBar()
    /// The entry's top: the pane's while the find bar is hidden, the bar's bottom while it is shown. A hidden view keeps
    /// its height in Auto Layout, so the bar must leave the chain, not merely hide (a 36 pt band otherwise).
    private var entryBelowPane: NSLayoutConstraint?
    private var entryBelowFind: NSLayoutConstraint?

    /// Why nothing is rendered, while that is so.
    public private(set) var refusal: EntryRefusal?
    /// The consent prompt on screen, if one is: the E2E stage clicks its buttons as a reader would.
    public private(set) var presentedPrompt: NSAlert?
    /// The read-back of the switches on the current web view's preferences, for the record.
    public var switchesReadBack: [String: Bool] { shownPane?.switchesReadBack ?? [:] }
    /// The current web view, if one exists: for the window's focus and for the E2E lab's instruments. On the All page,
    /// the shown dictionary's frame.
    public var webView: WKWebView? { shownPane?.view }
    /// The dictionary the last link, sound or spoken word came from: on the All page, that frame's; else the shown one.
    public var binding: EntryBinding? { (activePane.flatMap { owns($0) ? $0 : nil } ?? shownPane)?.binding }
    /// On the All page, the item (`EntryPageItem.id`) whose frame the last link, sound or spoken word came from.
    public var activeItem: UUID? {
        guard let page else { return nil }
        if let activePane, let section = page.sections.first(where: { $0.pane === activePane }) { return section.id }
        return primaryItem
    }
    /// The single entry's pane, or the All page's shown dictionary's frame.
    private var shownPane: EntryPane? {
        if let pane { return pane }
        guard let page else { return nil }
        return page.sections.first { $0.id == primaryItem }?.pane ?? page.panes.first
    }
    /// The pane a command about "the entry" means: the single entry's, or the page's frame in focus.
    private var focusPane: EntryPane? { pane ?? page?.frameInFocus(window: view.window) }
    /// Every pane shown: the single entry's, or each frame of the page.
    private var allPanes: [EntryPane] { pane.map { [$0] } ?? page?.panes ?? [] }
    /// **The key-view order** (lookup E2E, 2026-10-18): Tab from `keyViewPredecessor` (the window's results list) reaches
    /// `keyViewTarget`, and Shift-Tab from any frame returns to it. Re-applied whenever a pane or the page's frames change.
    public weak var keyViewPredecessor: NSView? { didSet { relinkKeyViews() } }
    /// Where Tab from the results lands: the single entry's web view, or the page's first frame on screen.
    public var keyViewTarget: NSView? { pane?.view ?? page?.firstKeyView }

    private func relinkKeyViews() {
        for pane in allPanes { pane.view.keyViewPredecessor = keyViewPredecessor }
    }

    /// The All page's sections, while it is shown (tests and instruments).
    var pageSections: [EntryPageSection]? { page?.sections }
    var pagePanes: [EntryPane]? { page?.panes }
    /// How long the All page took from being asked to its first frame's document loaded: first paint (P15).
    public var pageFirstPaint: Duration? { page?.firstPaint }
    /// How many of the page's frames exist, of how many dictionaries: frames are made lazily.
    public var pageFrames: (made: Int, of: Int)? { page.map { ($0.panes.count, $0.sections.count) } }
    /// The page's frames that exist, top to bottom (the lab's measurement).
    public var pageWebViews: [WKWebView] { page?.panes.map(\.view) ?? [] }
    /// Whether every frame made so far has loaded its document.
    public var pageLoaded: Bool { page?.sections.allSatisfy { $0.pane == nil || $0.finished } ?? false }

    private func owns(_ pane: EntryPane) -> Bool {
        pane === self.pane || page?.panes.contains { $0 === pane } == true
    }
    /// Where this view's per-dictionary choices are kept: the content it shows reads "Original style" from the same.
    public var preferences: EntryPreferences { environment.preferences }
    /// A choice changed elsewhere (the Library's "Original style") reaches the shown entry at once.
    private var preferencesObserver: (any NSObjectProtocol)?
    public var lastFind: EntryFindResult? { findBar.result }

    public init(environment: EntryEnvironment = EntryEnvironment()) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func loadView() {
        let root = AppearanceTrackingView()
        root.onAppearanceChange = { [weak self] in self?.applyPreferences() }
        preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
        message.isHidden = true
        message.isSelectable = true
        findBar.isHidden = true
        findBar.onQuery = { [weak self] query in self?.performFind(query) }
        findBar.onStep = { [weak self] forward in self?.stepFind(forward: forward) }
        findBar.onDone = { [weak self] in self?.hideFind() }
        for view in [container, message, findBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let belowPane = container.topAnchor.constraint(equalTo: root.topAnchor)
        entryBelowPane = belowPane
        entryBelowFind = container.topAnchor.constraint(equalTo: findBar.bottomAnchor)
        NSLayoutConstraint.activate([
            belowPane,
            findBar.topAnchor.constraint(equalTo: root.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            message.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
        ])
        view = root
    }

    // MARK: - Showing

    /// Shows `reference` from `content`, landing at `landing` once it has loaded: in the current web view if it is bound
    /// to the same dictionary, else in a new one. Returns whether the document was handed to WebKit.
    @discardableResult
    public func show(_ reference: EntryReference, from content: any EntryContent, landing: EntryLanding = .top) async
        -> Bool {
        _ = view
        await compileRuleList()
        closePage()
        if let pane, pane.binding != content.binding || pane.closed {
            pane.close()
            self.pane = nil
        }
        if pane == nil {
            let scheme = currentScheme(for: content.binding.dictionary)
            switch EntryPane.open(content: content, confinement: environment.confinement, scheme: scheme,
                                  frame: currentFrame(for: content.binding.dictionary), style: environment.style,
                                  ruleList: ruleList, switches: environment.switches, host: self) {
            case .failure(let why):
                refuse(why)
                return false
            case .success(let made):
                pane = made
                made.view.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(made.view)
                NSLayoutConstraint.activate([
                    made.view.topAnchor.constraint(equalTo: container.topAnchor),
                    made.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    made.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    made.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                ])
                relinkKeyViews()
            }
        }
        guard let pane else { return false }
        refusal = nil
        message.isHidden = true
        pane.setZoom(environment.preferences.zoom())
        pane.setFrame(currentFrame(for: pane.binding.dictionary))
        let shown = await pane.show(reference, landing: landing)
        if !shown, self.pane === pane, pane.reference != reference {
            say(EntrySentences.entryFailed)
        }
        return shown
    }

    // MARK: - The All page (parity P15)

    /// **Shows every dictionary's entry on one page** (parity P15; ADR-0010 amendment of 2026-10-18), in `items`'
    /// order, each in a frame of its own made by the same gate as a single entry's (`EntryPane.open`): every
    /// confinement layer per frame. `primary` is the item the window counts as shown. Showing the page again keeps
    /// the frames whose dictionary and record are unchanged. A frame that cannot be made with every layer refuses the
    /// whole page. Returns whether the page was handed to WebKit.
    @discardableResult
    public func showPage(_ items: [EntryPageItem], primary: UUID?, landing: EntryLanding = .top) async -> Bool {
        _ = view
        await compileRuleList()
        if let pane {
            pane.close()
            self.pane = nil
        }
        let page = self.page ?? makePage()
        primaryItem = primary
        let offset: Double? = if case .offset(let y) = landing { y } else { nil }
        if let refusal = page.show(items, landing: offset) {
            refuse(refusal)
            return false
        }
        refusal = nil
        message.isHidden = true
        return !items.isEmpty
    }

    private func makePage() -> EntryPage {
        let page = EntryPage(preferences: environment.preferences, zoom: environment.preferences.zoom(),
                             style: EntryPageStyle(frame: environment.readingFrame)) { [weak self] section in
            guard let self else { return .failure(.ruleListUnavailable("the entry view is gone")) }
            let content = section.item.content
            return EntryPane.open(content: content, confinement: environment.confinement,
                                  scheme: currentScheme(for: content.binding.dictionary),
                                  frame: currentFrame(for: content.binding.dictionary), style: environment.style,
                                  ruleList: ruleList, switches: environment.switches, host: self)
        }
        page.onRefusal = { [weak self] why in self?.refuse(why) }
        page.onContentHeightChanged = { [weak self] in self?.onContentHeightChanged?() }
        page.onFramesChanged = { [weak self] in self?.relinkKeyViews() }
        container.addSubview(page.scroll)
        NSLayoutConstraint.activate([
            page.scroll.topAnchor.constraint(equalTo: container.topAnchor),
            page.scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            page.scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view.layoutSubtreeIfNeeded()
        self.page = page
        return page
    }

    private func closePage() {
        page?.close()
        page = nil
        primaryItem = nil
    }

    private func compileRuleList() async {
        guard ruleList == nil, environment.confinement.ruleList else { return }
        do {
            ruleList = .success(try await EntryRuleList.compile(in: environment.ruleListDirectory))
        } catch {
            ruleList = .failure(.ruleListUnavailable(String(describing: error)))
        }
    }

    /// The shown entry's height in points (its CSS height at its zoom), or the page's (`pageHeight`) while the page is
    /// shown; nil with none shown.
    public func documentHeight() async -> Double? {
        if let page { return page.contentHeight }
        guard let height = await pane?.documentHeight() else { return nil }
        return height * zoom
    }

    /// The page's height in points, its dividers and frames (P41: what the popover sizes to); nil with no page.
    public var pageHeight: Double? { page?.contentHeight }
    /// Told whenever the page's height may have changed (a frame grew or shrank, sections came or went).
    public var onContentHeightChanged: (() -> Void)?
    /// Whether the page paints a paper of its own: in the main window, not on the popover's glass.
    var pageDrawsBackground: Bool? { page?.scroll.drawsBackground }

    /// Each shown document once it has finished loading: the lookup panel measures it then.
    public var onDocumentFinished: (() -> Void)?

    /// How far down the shown entry the reader has scrolled, in CSS pixels; nil with none shown (the trail keeps it).
    public func scrollOffset() async -> Double? {
        if let page { return page.offset }
        return await pane?.scrollOffset()
    }

    /// "Expand All" and "Collapse All" (ADR-0010 Q4): every fold of the shown entry, as the reader's clicks would.
    @discardableResult
    public func expandAll(_ open: Bool = true) -> Task<Int, Never> {
        Task { @MainActor in
            var clicked = 0
            for pane in allPanes { clicked += await pane.expandAll(open) }
            return clicked
        }
    }

    /// The entry the view shows or is loading.
    public var reference: EntryReference? { shownPane?.reference }

    /// Closes the web view: nothing in flight is answered after this.
    public func closeEntry() {
        pane?.close()
        pane = nil
        closePage()
    }

    private func refuse(_ why: EntryRefusal) {
        refusal = why
        record(.refusedToRender(why))
        pane?.close()
        pane = nil
        closePage()
        say(EntrySentences.refusal(why))
    }

    private func say(_ sentence: LocalizedStringResource) {
        message.stringValue = String(localized: sentence)
        message.isHidden = false
    }

    // MARK: - Text size (Apple parity P29: one for every dictionary) and appearance (R4, per dictionary), kept

    public var zoom: Double { environment.preferences.zoom() }

    public func zoomIn() { setZoom(EntryPreferences.step(zoom, up: true)) }
    public func zoomOut() { setZoom(EntryPreferences.step(zoom, up: false)) }
    public func resetZoom() { setZoom(1) }

    /// The text size for every dictionary; with none shown it is kept for the next entry. Other windows follow through
    /// the defaults' change notice.
    public func setZoom(_ value: Double) {
        environment.preferences.setZoom(value)
        pane?.setZoom(environment.preferences.zoom())
        page?.setZoom(environment.preferences.zoom())
    }

    // MARK: - Print (Apple parity P32, P44)

    /// File ▸ Print…: what is shown, through the system's print panel, as a sheet on its window. The All page prints
    /// whole, every expanded dictionary under its name, as Apple's does (P44); a single entry prints its frame.
    public func printEntry() {
        guard let window = view.window else {
            EntryLog.logger.error("print: no window")
            return
        }
        if let page {
            Task { @MainActor in
                guard let printed = await page.printView() else {
                    EntryLog.logger.error("print: the All page could not be drawn for print")
                    return
                }
                // A copy: the page's pagination is not every later print's.
                let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
                info.horizontalPagination = .fit
                info.verticalPagination = .automatic
                // From the top of the paper, as Apple's prints, not centred on it.
                info.isVerticallyCentered = false
                NSPrintOperation(view: printed, printInfo: info)
                    .runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            }
            return
        }
        guard let webView = focusPane?.view else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    public var theme: EntryTheme {
        guard let binding = focusPane?.binding else { return .matchApp }
        return environment.preferences.theme(for: binding.dictionary)
    }

    public func setTheme(_ theme: EntryTheme) {
        guard let pane = focusPane else { return }
        environment.preferences.setTheme(theme, for: pane.binding.dictionary)
        applyPreferences()
    }

    /// Whether this dictionary is shown in its own style, without the reading frame (ADR-0010 Q3).
    public var originalStyle: Bool {
        guard let binding = focusPane?.binding else { return false }
        return environment.preferences.originalStyle(for: binding.dictionary)
    }

    public func setOriginalStyle(_ original: Bool) {
        guard let pane = focusPane else { return }
        environment.preferences.setOriginalStyle(original, for: pane.binding.dictionary)
        applyPreferences()
    }

    private func currentFrame(for dictionary: String) -> EntryReadingFrame {
        environment.readingFrame.applied(originalStyle: environment.preferences.originalStyle(for: dictionary))
            .with(accent: environment.preferences.accent())
    }

    private func currentScheme(for dictionary: String) -> EntryColourScheme {
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return environment.preferences.theme(for: dictionary).scheme(appIsDark: dark)
    }

    private func applyPreferences() {
        pane?.setZoom(environment.preferences.zoom())
        page?.setZoom(environment.preferences.zoom())
        for pane in allPanes {
            pane.setFrame(currentFrame(for: pane.binding.dictionary))
            pane.setScheme(currentScheme(for: pane.binding.dictionary))
        }
    }

    // MARK: - Find (R3)

    private func setFindShown(_ shown: Bool) {
        findBar.isHidden = !shown
        // The one that goes is deactivated first, so the two never hold at once.
        let (on, off) = shown ? (entryBelowFind, entryBelowPane) : (entryBelowPane, entryBelowFind)
        off?.isActive = false
        on?.isActive = true
    }

    public func showFind() {
        setFindShown(true)
        view.window?.makeFirstResponder(findBar.field)
    }

    public func hideFind() {
        setFindShown(false)
        Task {
            if let page { await page.clearFind() } else { await pane?.clearFind() }
        }
        if let webView = focusPane?.view { view.window?.makeFirstResponder(webView) }
    }

    /// Finds `query` in the shown entry and returns the count; the find bar shows it too.
    @discardableResult
    public func performFind(_ query: String) -> Task<EntryFindResult?, Never> {
        Task { @MainActor in
            let result = if let page { await page.find(query) } else { await pane?.find(query) }
            findBar.show(result, query: query)
            return result
        }
    }

    /// Edit ▸ Find ▸ Use Selection for Find (⌘E, P33): the entry's selected text becomes the find bar's query.
    @discardableResult
    public func useSelectionForFind() -> Task<EntryFindResult?, Never> {
        Task { @MainActor in
            guard let selected = await focusPane?.selectedText(), !selected.isEmpty else { return nil }
            setFindShown(true)
            findBar.field.stringValue = selected
            return await performFind(selected).value
        }
    }

    /// Edit ▸ Find ▸ Jump to Selection (⌘J, P33): the entry scrolled to its selection.
    public func jumpToSelection() {
        Task { @MainActor in await focusPane?.jumpToSelection() }
    }

    @discardableResult
    public func stepFind(forward: Bool) -> Task<EntryFindResult?, Never> {
        Task { @MainActor in
            let result = if let page { await page.findStep(forward: forward) } else {
                await pane?.findStep(forward: forward)
            }
            findBar.show(result, query: findBar.field.stringValue)
            return result
        }
    }

    // MARK: - EntryPaneHost

    func record(_ event: EntryEvent) {
        EntryLog.record(event)
        environment.events(event)
    }

    func perform(_ action: EntryLinkAction, from pane: EntryPane) {
        guard owns(pane) else { return }
        activePane = pane
        switch action {
        case .lookup(let query, let anchor): onLookup?(query, anchor)
        case .sound(let path): onSound?(path)
        case .speak(let text): onSpeak?(text)
        case .scroll, .askReader, .nothing: break
        }
    }

    func askReader(_ url: URL, from pane: EntryPane) {
        guard owns(pane) else { return }
        guard let window = view.window else {
            record(.remotePromptDropped(url: url.absoluteString))
            return
        }
        switch gate.request(url) {
        case .drop:
            record(.remotePromptDropped(url: url.absoluteString))
        case .ask(let remote, let host):
            record(.remotePromptRaised(url: remote.absoluteString))
            let alert = NSAlert()
            alert.messageText = String(localized: EntrySentences.openRemote(host: host))
            alert.informativeText = String(localized: EntrySentences.openRemoteDetail(url: remote.absoluteString))
            alert.addButton(withTitle: String(localized: EntrySentences.openInBrowser))
            alert.addButton(withTitle: String(localized: EntrySentences.cancel))
            presentedPrompt = alert
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated { self?.answered(response == .alertFirstButtonReturn) }
            }
        }
    }

    private func answered(_ consent: Bool) {
        let asked = gate.asking
        presentedPrompt = nil
        let opened = gate.answer(consent: consent)
        record(.remotePromptAnswered(url: asked?.absoluteString ?? "", consent: consent))
        if let opened {
            record(.remoteOpened(url: opened.absoluteString))
            environment.opener.open(opened)
        }
    }

    func newWindow(_ configuration: WKWebViewConfiguration, for action: WKNavigationAction) -> WKWebView? {
        environment.newWindow?(configuration, action)
    }

    func documentFinished(_ pane: EntryPane) {
        if let page, page.panes.contains(where: { $0 === pane }) {
            page.finished(pane)
            if pane === shownPane { onDocumentFinished?() }
            return
        }
        guard pane === self.pane else { return }
        onDocumentFinished?()
        guard !findBar.isHidden, !findBar.field.stringValue.isEmpty else { return }
        performFind(findBar.field.stringValue)
    }
}

/// A view that says when the app's appearance changes under it.
private final class AppearanceTrackingView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// The find bar: a field, the count, previous and next, and done. Matches in folded sections are counted apart.
@MainActor
final class EntryFindBar: NSView {
    let field = NSSearchField()
    let count = NSTextField(labelWithString: "")
    /// Previous and Next as one chevron pair, as Safari's and TextEdit's find bars draw them (UI review M-14).
    let steps = NSSegmentedControl()
    private let done = NSButton()
    var onQuery: ((String) -> Void)?
    var onStep: ((Bool) -> Void)?
    var onDone: (() -> Void)?
    private(set) var result: EntryFindResult?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = String(localized: EntrySentences.findPlaceholder)
        field.setAccessibilityLabel(String(localized: EntrySentences.findPlaceholder))
        field.sendsSearchStringImmediately = false
        field.target = self
        field.action = #selector(queried)
        steps.segmentCount = 2
        steps.trackingMode = .momentary
        steps.segmentStyle = .separated
        for (segment, symbol, name) in [(0, "chevron.left", EntrySentences.previous), (1, "chevron.right", EntrySentences.next)] {
            let title = String(localized: name)
            steps.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: title), forSegment: segment)
            steps.setToolTip(title, forSegment: segment)
            steps.setWidth(26, forSegment: segment)
        }
        steps.target = self
        steps.action = #selector(stepped)
        done.title = String(localized: EntrySentences.done)
        done.bezelStyle = .push
        done.target = self
        done.action = #selector(finish)
        let row = NSStackView(views: [field, count, steps, done])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: Tokens.Space.s, left: Tokens.Space.sm, bottom: Tokens.Space.s, right: Tokens.Space.sm)
        row.translatesAutoresizingMaskIntoConstraints = false
        // The bar's edge against the entry under it.
        let edge = NSBox()
        edge.boxType = .separator
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(edge)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            edge.leadingAnchor.constraint(equalTo: leadingAnchor), edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func queried() { onQuery?(field.stringValue) }
    @objc private func stepped() { onStep?(steps.selectedSegment == 1) }
    @objc private func finish() { onDone?() }

    func show(_ result: EntryFindResult?, query: String) {
        self.result = result
        guard let result, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            count.stringValue = ""
            count.setAccessibilityLabel(nil)
            return
        }
        var text = result.visible == 0 ? String(localized: EntrySentences.noMatches)
            : String(localized: EntrySentences.matchPosition(result.current, of: result.visible))
        if result.hidden > 0 { text += " · " + String(localized: EntrySentences.hiddenMatches(result.hidden)) }
        count.stringValue = text
        count.setAccessibilityLabel(text)
    }
}

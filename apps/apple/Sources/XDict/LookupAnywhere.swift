import AppKit
import ApplicationServices
import Observation
import SwiftUI
import XDictAnywhere
import XDictCapture
import XDictCaptureMac
import XDictBase
import XDictContract
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictUI
import os

/// **Lookup from anywhere** (plan-macos-v1 WI-8): a selection in any app reaches a panel by it — by the lookup shortcut
/// (the selection read through the Accessibility API), by the Service "Look Up in XDict" (the text macOS hands over), by
/// the menu-bar item, or by hovering a word with the hover key (plan-capture WI-3) — and the panel expands into the main
/// window keeping query, dictionary and scroll (I5). Dismissal by Escape or a click elsewhere leaves the reader's app in
/// front, its next key reaching it (I6): **the panel never activates XDict and never becomes key**.
///
/// **It is capture's sink** (ADR-0014 decision 4): every trigger's request is numbered in the one `CaptureRequests` when it
/// is asked, the shortcut's, the Service's and the menu's claiming presentation at once and a hover's when its word
/// arrives; each term is handed over by `present`, and each request ends exactly once — the popover's acknowledgement per
/// generation (`PresentationAcks`), or cancelled. **Only the term goes to search and the hooks**; a hover's sentence stays
/// in the one ephemeral `CaptureContextSession`, dropped when the panel closes (decision 9).
@MainActor
@Observable
final class LookupAnywhere {
    /// Where a lookup came from: what the instruments record, and what places the panel.
    enum Source: String {
        case shortcut, service, menu, hover

        init(_ trigger: CaptureTrigger) {
            switch trigger {
            case .selection: self = .shortcut
            case .service: self = .service
            case .menu: self = .menu
            case .pointerGesture: self = .hover
            }
        }
    }

    static let shared = LookupAnywhere()
    /// Which launch this is (`main.swift`): in one a development instrument drives, hover is not started, so a held key
    /// in a driven run never opens a lookup nobody asked for.
    static var launch: HoverLaunch = .reader

    /// Hover's settings, pause and watcher, and **the app's one book of capture requests**, every trigger's.
    @ObservationIgnored private(set) lazy var hover = HoverControl(
        defaults: .standard, requests: CaptureRequests(),
        scripts: { HoverScripts.allowed(searchLanguages: XDictApp.library.entries.filter(\.enabled).map(\.languages.pair.search)) })
    private var requests: CaptureRequests { hover.requests }
    /// The presented request's context, and nothing else of it: memory only, cleared when the panel closes. Capture's own
    /// session (hover's), whose book holds a recognised word's pending context, so its handle is found here.
    private var contextSession: CaptureContextSession { hover.contextSession }
    /// What the popover owes the request it presents.
    @ObservationIgnored private var acks = PresentationAcks()
    /// The query whose entry, or settled nothing-found, the visible popover has drawn.
    @ObservationIgnored private var drawnQuery: String?

    /// How long the selection may take before the panel shows by the pointer, saying it is reading: the panel's budget is
    /// 1 s from the key (the E2E `panel.deadline` sub-stage), and a hung app may take the read's whole 2 s.
    static let readGrace: Duration = .milliseconds(300)
    /// Opening size: the Look Up popover's 390 pt body (P41), 180 pt tall while the entry loads (Codex §3); the entry
    /// then sets the height.
    static let panelSize = CGSize(width: PanelPlacement.widths.default, height: PanelPlacement.initialHeight)
    /// Whether a measured height is taken: not under 2 pt, not from an earlier entry.
    @ObservationIgnored private var fit = PanelFit()
    @ObservationIgnored private var shownEntry = 0

    @ObservationIgnored private(set) lazy var registrar = ShortcutRegistrar(
        defaults: .standard, hotkeys: .shared) { [weak self] in self?.pressed() }
    private(set) var notice = PanelNotice.none
    /// The panel's own search and entry view: made once, at launch, so the first lookup does not wait for a web view.
    @ObservationIgnored private var state: SearchWindowState?
    @ObservationIgnored private var panel: LookupPopover?
    @ObservationIgnored private var content: NSView?
    @ObservationIgnored private var escape: EscapeStack.Entry?
    @ObservationIgnored private var clickMonitors: [Any] = []
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// The brief line by the pointer for a hover that read nothing.
    @ObservationIgnored private let briefNotice = HoverNoticeHUD()
    @ObservationIgnored private let log = Logger(subsystem: XDictIdentity.app, category: "anywhere")
    /// Opens a main window: set by the scene, which alone holds SwiftUI's `openWindow`.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// What the panel and the expansion did, for the instruments (`AnywhereReport`).
    @ObservationIgnored var observe: ((String, [String: Any]) -> Void)?

    var isShown: Bool { panel?.isShown == true }
    var panelState: SearchWindowState? { state }
    var panelFrame: CGRect? { panel?.frame }

    /// Registers the shortcut, offers the Service, and readies the panel. Once, at launch.
    /// The last app other than XDict to be frontmost: where a Service request came from, when it brought XDict forward.
    @ObservationIgnored private var lastOtherApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    /// Where the reader last right-clicked or Control-clicked, and when: where a Service request's selection is, when
    /// its app cannot say. A global mouse monitor, which needs no permission.
    @ObservationIgnored private var lastSecondaryClick: (point: CGPoint, at: Date)?
    @ObservationIgnored private var secondaryClickMonitor: Any?
    @ObservationIgnored private var ownClickMonitor: Any?

    func start() {
        guard state == nil else { return }
        lastOtherApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
        // A global monitor is not sent the app's own events, so a right-click in XDict's own windows needs the local one
        // too; without it the Service from an entry found no click and anchored at the pointer, in the Services submenu
        // (owner's screenshot, 2026-10-18: the popover's arrow pointed well away from the word).
        let remember: (NSEvent) -> Void = { [weak self] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return }
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.lastSecondaryClick = (point, Date()) }
        }
        secondaryClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown], handler: remember)
        ownClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            remember(event)
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.processIdentifier != getpid() { self?.lastOtherApp = app }
            }
        }
        NSApp.servicesProvider = ServicesProvider.shared
        NSUpdateDynamicServices()
        registrar.registerSaved()
        let made = XDictApp.windowState(panel: true)
        // A section's "Show in Settings" closes the panel and opens Settings at that dictionary (ADR-0012 d.4).
        made.showDictionaries = { [weak self] id in
            self?.close(why: "showDictionaries")
            MenuBarActions.showDictionaries(id)
        }
        state = made
        hover.watcher.sink = self
        // A hover that read nothing, or needed a grant, says so by the pointer (owner's report, 2026-10-19).
        hover.showBriefNotice = { [weak self] notice in
            self?.briefNotice.show(String(localized: HoverSentences.brief(notice)), near: NSEvent.mouseLocation)
        }
        hover.startAtLaunch(Self.launch)
    }

    // MARK: - Asking

    /// The shortcut: the selection of the app in front, or — with the panel showing that very lookup — expansion, the
    /// panel's keyboard route (it takes no keys of its own).
    func pressed() {
        // **Numbered now, at the key**, before anything is read (ADR-0014 decision 4).
        pressed(as: requests.beginPresenting(.selection))
    }

    /// The shortcut or the menu, for `request`.
    private func pressed(as request: CaptureRequest) {
        let pressedAt = ContinuousClock.now
        let source = Source(request.trigger)
        observe?("pressed", ["request": request.number])
        guard let front = FrontApp.frontmost(), front.pid != getpid() || !isShown else {
            requests.cancel(request)
            if isShown { expand() } else { show(.refused(.noApp), query: nil, near: nil, source: source) }
            return
        }
        // No grant: the system's own request, once; the panel says what to do; the grant resumes this lookup.
        switch gate.request() {
        case .trusted:
            break
        case .asked, .waiting:
            requests.cancel(request)
            gate.onGranted = { [weak self] in self?.resume(front, trigger: request.trigger) }
            startPolling()
            show(.refused(.notTrusted), query: nil, near: nil, source: source)
            return
        }
        read(front, request: request, pressedAt: pressedAt)
    }

    @ObservationIgnored let gate = AccessibilityGate(check: AccessibilityGate.system)
    @ObservationIgnored private var polling: Task<Void, Never>?

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { @MainActor [weak self] in
            while let gate = self?.gate, gate.isWaiting, !Task.isCancelled {
                try? await Task.sleep(for: AccessibilityGate.interval)
                gate.poll()
            }
            self?.polling = nil
        }
    }

    /// The grant arrived while the request was open: the lookup that found none, carried on — as a new request of the same
    /// trigger, since the one that found no grant ended.
    private func resume(_ front: FrontApp, trigger: CaptureTrigger) {
        observe?("granted", [:])
        guard NSRunningApplication(processIdentifier: front.pid) != nil else { return }
        read(front, request: requests.beginPresenting(trigger), pressedAt: .now)
    }

    private func read(_ front: FrontApp, request: CaptureRequest, pressedAt: ContinuousClock.Instant) {
        reading?.cancel()
        let source = Source(request.trigger)
        // The reader's exclusions as they are at the key: they decide whether the sentence around the selection is read.
        let exclusions = hover.policy
        reading = Task { [weak self] in
            // The panel shows that it is reading if the read outlasts the grace; the answer replaces that.
            let waiting = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.readGrace)
                guard !Task.isCancelled else { return }
                self?.show(.reading, query: nil, near: nil, source: source)
            }
            let outcome = await SelectionReader.read(from: front, excluding: exclusions)
            waiting.cancel()
            guard let self else { return }
            guard !Task.isCancelled else {
                self.requests.cancel(request)
                return
            }
            self.answer(outcome, request: request, pressedAt: pressedAt)
        }
    }

    private func answer(_ outcome: SelectionOutcome, request: CaptureRequest, pressedAt: ContinuousClock.Instant) {
        let source = Source(request.trigger)
        switch outcome {
        case .selected(let selected, _):
            if isShown, notice == .none, state?.model.lookup?.query == selected.text {
                requests.cancel(request)
                expand()  // the same selection again: the keyboard route to the main window
                return
            }
            do {
                guard let term = try outcome.capturedTerm(trigger: request.trigger) else {
                    requests.cancel(request)
                    return
                }
                // Shown by `deliver`, the sink's one way in; a request overtaken meanwhile is refused and ends there.
                _ = requests.present(term, for: request, to: self)
            } catch {
                // A selection the validating constructor refuses (a control character in it) is not a term.
                requests.cancel(request)
                show(.refused(.noWord(app: selected.app.name)), query: nil, near: nil, source: source)
            }
        case .nothing(let refusal):
            requests.cancel(request)
            show(.refused(refusal), query: nil, near: nil, source: source)
        }
        let elapsed = ContinuousClock.now - pressedAt
        log.info("selection answered in \(elapsed.components.attoseconds / 1_000_000_000_000_000 + elapsed.components.seconds * 1000) ms")
    }

    /// The Service: the text macOS handed over, looked up **by the selection** — its box where XDict may read it and
    /// it is the text handed over, else where the reader Control-clicked it (the pointer itself has moved on, into the
    /// Services submenu). Measured on the E2E Mac (2026-10-15): macOS brings the provider forward a moment after the
    /// request, so the reader's app — the last other app in front — is put back in front, and the panel's dismissal
    /// leaves it there with its next key.
    func service(_ raw: String?) {
        // **Numbered now, as macOS hands the text over**, before the selection is read for its place.
        let request = requests.beginPresenting(.service)
        observe?("service", ["text": raw ?? NSNull(), "request": request.number])
        switch LookupText.term(raw) {
        case .term(let text):
            let previous = lastOtherApp
            observe?("serviceFront", ["xdictWasActive": NSApp.isActive, "previous": previous?.bundleIdentifier ?? NSNull()])
            let clicked = lastSecondaryClick.flatMap { Date().timeIntervalSince($0.at) < 15 ? $0.point : nil }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Back to the reader's app first, and only then its selection read: an app that is not frontmost
                // answers for no focused element (TextEdit, Notes), and a host waits for the Service's answer
                // before it answers anything else.
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(50))
                    let front = NSWorkspace.shared.frontmostApplication
                    if front?.processIdentifier == getpid() { previous?.activate() }
                    if let previous, front == previous { break }
                }
                // The click in Accessibility's coordinates (y down): the element there holds the selection where the
                // reader's app, back in front after the Services menu, names no focused one (Notes, TextEdit).
                let under = clicked.map { UpPoint($0).flipped(aboutPrimaryHeight: Self.primaryHeight) }
                var outcome: SelectionOutcome?
                if AXIsProcessTrusted(), let reader = previous.flatMap(FrontApp.resolving), reader.pid != getpid() {
                    outcome = await SelectionReader.read(from: reader, clicked: under?.cg, excluding: self.hover.policy)
                    self.observe?("serviceSelection", ["outcome": String(describing: outcome).prefix(300).description])
                }
                // **The Service's text is the query**, whatever the selection now says; the read supplies the box only
                // where it agrees, else where the reader Control-clicked, as a word of no width (Chrome gives no box).
                do {
                    let term = try SelectionReader.serviceTerm(
                        text, read: outcome, source: SourceApp(bundleID: previous?.bundleIdentifier), clicked: under)
                    _ = self.requests.present(term, for: request, to: self)
                } catch {
                    self.requests.cancel(request)
                    self.show(.refused(.noWord(app: "")), query: nil, near: nil, source: .service)
                }
            }
        case .empty:
            requests.cancel(request)
            show(.refused(.nothingSelected(app: "")), query: nil, near: nil, source: .service)
        case .noWord:
            requests.cancel(request)
            show(.refused(.noWord(app: "")), query: nil, near: nil, source: .service)
        case .tooLong(let characters):
            requests.cancel(request)
            show(.refused(.tooLong(app: "", characters: characters)), query: nil, near: nil, source: .service)
        }
    }

    /// The menu-bar item's Look Up Selection: as the shortcut — numbered at the click — once the menu has closed and the
    /// reader's app is in front again.
    func lookUpFromMenu() {
        let request = requests.beginPresenting(.menu)
        observe?("menu", ["request": request.number])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.pressed(as: request)
        }
    }

    // MARK: - Capture's sink

    /// A term presented for its request: shown in the popover, the term alone to search, its context to the session.
    private func accept(_ delivery: CaptureDelivery) -> CaptureDeliveryAnswer {
        guard state != nil else { return .refused }
        let term = delivery.term
        contextSession.hold(term.context, request: delivery.request.number, generation: delivery.generation)
        acks.delivered(delivery.request, generation: delivery.generation, term: term.term)
        if drawnQuery != term.term { drawnQuery = nil }
        show(.none, query: term.term, near: PanelAnchor.rect(for: term.box, primaryHeight: Self.primaryHeight),
             source: Source(delivery.request.trigger))
        observe?("presented", ["request": delivery.request.number, "generation": delivery.generation,
                               "trigger": delivery.request.trigger.rawValue])
        if let ack = acks.shown(popoverVisible: isShown) { acknowledge(ack) }
        // The same term already drawn in the popover: shown at once, as nothing new will draw.
        if drawnQuery == term.term, let ack = acks.drew(query: term.term, popoverVisible: isShown) { acknowledge(ack) }
        return .accepted
    }

    /// The panel drew a lookup of `query`: the presented request's acknowledgement, where it is that request's.
    private func drew(query: String?) {
        guard isShown else { return }
        drawnQuery = query
        if let ack = acks.drew(query: query, popoverVisible: isShown) { acknowledge(ack) }
    }

    /// The panel's placeholder changed: a settled nothing-found is a drawn lookup of its query.
    fileprivate func placeholderChanged(_ placeholder: EntryPlaceholder) {
        switch placeholder {
        case .noResults, .noResultsIncomplete, .noDictionaries: drew(query: state?.model.lookup?.query)
        case .start, .searching, .none: break
        }
    }

    private func acknowledge(_ ack: PresentationAck) {
        requests.acknowledge(ack.request, generation: ack.generation, ack.outcome)
        observe?("acknowledged", ["request": ack.request.number, "generation": ack.generation,
                                  "outcome": ack.outcome.rawValue])
    }

    // MARK: - The panel

    private func show(_ notice: PanelNotice, query: String?, near word: CGRect?, source: Source) {
        guard let state else { return }
        self.notice = notice
        if let query { state.model.submit(query) }
        let panel = self.panel ?? makePanel(state)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(word.map { CGPoint(x: $0.midX, y: $0.midY) } ?? pointer) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: Self.panelSize)
        // While shown, the popover keeps its size (its entry's) and its anchor; a new showing opens at the default.
        if !panel.isShown || notice != .reading, let content {
            let size = panel.isShown ? panel.bodySize : Self.panelSize
            panel.show(content, size: size, word: word, pointer: pointer, visible: visible)
        }
        let frame = panel.frame ?? .zero
        if escape == nil {
            escape = HotkeyCenter.shared.escape.push { [weak self] in self?.close(why: "escape") }
        }
        watchForClicksAway()
        observe?("shown", ["source": source.rawValue, "query": query ?? NSNull(), "frame": Self.describe(frame),
                           "word": word.map(Self.describe) ?? NSNull(), "notice": String(describing: notice)])
    }

    private func makePanel(_ state: SearchWindowState) -> LookupPopover {
        let panel = LookupPopover()
        let host = NSHostingView(rootView: PanelRoot(anywhere: self, state: state))
        host.setAccessibilityIdentifier("lookupPanel")
        content = host
        // Closed by itself (a click elsewhere in XDict): the same bookkeeping as every other way it closes.
        panel.onClose = { [weak self] in self?.close(why: "clickAway") }
        state.entry.onDocumentFinished = { [weak self] in self?.entryFinished() }
        state.entry.onContentHeightChanged = { [weak self] in self?.stackChanged() }
        self.panel = panel
        return panel
    }

    /// **The stack's height changed** (P41): a frame took its document's height, or a dictionary joined. The popover
    /// follows, once per turn of the run loop however many frames moved, up to its cap, past which the stack scrolls
    /// as one.
    @ObservationIgnored private var stackFit: Task<Void, Never>?
    private func stackChanged() {
        guard stackFit == nil else { return }
        stackFit = Task { @MainActor in
            await Task.yield()
            self.stackFit = nil
            await self.fitToEntry(self.shownEntry)
        }
    }

    /// A new entry finished loading: measured now and again as its fonts and images settle (0.4, 1.2 and 3 s), each
    /// measure taken only if it is this entry's and moves the panel by 2 pt or more, so a settled entry never
    /// oscillates (Codex §3). Polled from here rather than a ResizeObserver in the page: the entry page's scripts are
    /// the confinement's, and the settling an observer would catch happens within those passes.
    private func entryFinished() {
        // A document finished in the popover: the presented term's, if the panel's query is still its own.
        drew(query: state?.model.lookup?.query)
        shownEntry += 1
        fit.began(entry: shownEntry)
        let entry = shownEntry
        Task { @MainActor in
            for delay in [0.0, 0.4, 1.2, 3.0] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard entry == self.shownEntry else { return }
                await self.fitToEntry(entry)
            }
        }
    }

    /// The panel as tall as its entry, within bounds and the screen's room (UI review P-03, Codex §3), its top edge
    /// kept where it is unless that would leave the screen.
    private func fitToEntry(_ entry: Int) async {
        guard let state else { return }
        let document = await state.entry.documentHeight()
        guard let panel, panel.isShown else { return }
        let visible = (panel.anchor.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let height = PanelPlacement.height(document: document, chrome: LookupPanelView.chromeHeight,
                                           available: visible.height - 2 * PanelPlacement.margin)
        guard fit.accepts(height: height, current: panel.bodySize.height, entry: entry) else { return }
        panel.resize(height: height)
    }

    func close(why: String) {
        reading?.cancel()
        // **Closing supersedes every request so far** (ADR-0014 decision 4): each still open ends cancelled, a late result
        // is not presented over the dismissal, and the presented request's context goes with the panel (decision 9).
        requests.close()
        contextSession.clear()
        acks.closed()
        drawnQuery = nil
        guard let panel, panel.isShown || escape != nil else { return }
        panel.close()
        if let escape { HotkeyCenter.shared.escape.pop(escape) }
        escape = nil
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors = []
        observe?("closed", ["why": why])
    }

    /// A click anywhere but the panel closes it: a global monitor for other apps' clicks (mouse events need no
    /// permission), a local one for XDict's own windows — whose event is returned, never swallowed. A click in the
    /// panel's own pop-up menu is the panel's.
    private func watchForClicksAway() {
        guard clickMonitors.isEmpty else { return }
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            let point = NSEvent.mouseLocation
            _ = event
            MainActor.assumeIsolated { self?.closeIfAway(point, window: nil) }
        }) { clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] event in
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
            MainActor.assumeIsolated { self?.closeIfAway(point, window: event.window) }
            return event
        }) { clickMonitors.append(local) }
    }

    private func closeIfAway(_ point: CGPoint, window: NSWindow?) {
        guard let panel, panel.isShown else { return }
        let popoverWindow = panel.popover.contentViewController?.view.window
        if window === popoverWindow || (panel.frame?.contains(point) ?? false) { return }
        if let window, window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue { return }
        close(why: "clickAway")
    }

    // MARK: - Expanding (I5)

    /// Into the main window, keeping query, dictionary and scroll: the panel's place, with its entry's offset, handed to
    /// the main window's model as its next place; then XDict comes forward, as the reader asked.
    func expand() {
        guard let state else { return }
        Task { @MainActor in
            guard let place = await state.model.currentPlace() else {
                if let query = state.model.lookup?.query { MainWindows.hand(Visit(query: query, mode: .reader, scope: .all,
                                                                                  isOrigin: true)) }
                self.finishExpanding(nil)
                return
            }
            MainWindows.hand(place)
            self.finishExpanding(place)
        }
    }

    private func finishExpanding(_ place: Visit?) {
        close(why: "expanded")
        NSApp.activate()
        if !MainWindows.deliver() { openMainWindow?() }
        observe?("expanded", ["query": place?.query ?? NSNull(),
                              "dictionary": place?.result?.dictionary.uuidString ?? NSNull(),
                              "key": place?.result?.entry.key ?? NSNull(), "scroll": place?.scroll ?? NSNull()])
    }

    // MARK: -

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func describe(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}

/// The panel's SwiftUI root: the content, redrawn as the notice and the shortcut change.
private struct PanelRoot: View {
    let anywhere: LookupAnywhere
    let state: SearchWindowState

    var body: some View {
        LookupPanelView(state: state, notice: anywhere.notice,
                        shortcut: anywhere.registrar.isRegistered ? anywhere.registrar.current.label() : nil,
                        expand: { anywhere.expand() },
                        showDictionaries: {
                            anywhere.close(why: "showDictionaries")
                            MenuBarActions.showDictionaries()
                        })
            .onChange(of: state.placeholder) { _, placeholder in anywhere.placeholderChanged(placeholder) }
    }
}

/// **The sink's one way in** (ADR-0014 decision 4). `CaptureSink` is called synchronously by `CaptureRequests.present`,
/// which every trigger reaches from the main actor; the assumption is checked, and fails loud where it is wrong.
extension LookupAnywhere: CaptureSink {
    nonisolated func deliver(_ delivery: CaptureDelivery) -> CaptureDeliveryAnswer {
        MainActor.assumeIsolated { accept(delivery) }
    }
}

/// **The Service** "Look Up in XDict" (`NSServices` in Info.plist, with `NSRequiredContext` so macOS offers it in a
/// selection's context menu without the reader enabling it): the selected text, by the pasteboard macOS hands over.
final class ServicesProvider: NSObject {
    @MainActor static let shared = ServicesProvider()

    @objc func lookUpInXDict(_ pasteboard: NSPasteboard, userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pasteboard.string(forType: .string)
        MainActor.assumeIsolated { LookupAnywhere.shared.service(text) }
    }
}

/// **The main windows, and a place handed to one** (I5): the frontmost existing main window takes it; with none, the
/// next one made does, at its first appearance.
@MainActor
enum MainWindows {
    private static var states: [WeakState] = []
    private static var pending: Visit?

    private struct WeakState { weak var state: SearchWindowState? }

    static func made(_ state: SearchWindowState) {
        states.removeAll { $0.state == nil }
        states.append(WeakState(state: state))
        if pending != nil { _ = deliver() }
    }

    static func hand(_ place: Visit) { pending = place }

    /// Gives the pending place to the most recent main window still open, and brings that window forward; false when
    /// there is none.
    static func deliver() -> Bool {
        states.removeAll { $0.state == nil }
        guard let place = pending, let state = states.last?.state else { return false }
        pending = nil
        state.model.adopt(place)
        state.focusSearch()
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(XDictApp.mainWindow) == true && $0.isVisible }?
            .makeKeyAndOrderFront(nil)
        return true
    }

    /// The main window holding a state, and what it shows: for the instruments.
    static var front: SearchWindowState? { states.last { $0.state != nil }?.state }
}

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
    /// XDict's own entry views are read by their own script, never through Accessibility (`EntryWebView.hoverText`).
    @ObservationIgnored private(set) lazy var hover = HoverControl(
        defaults: .standard, requests: CaptureRequests(),
        source: SystemPointerWords(metrics: CaptureTolerances.metrics, readsOwnView: Self.readsOwnEntry),
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
    /// The shown entry whose finished document was already recorded: the entry view may report one document twice, and a
    /// second report is not a second reading (plan-history-and-learning §2.2).
    @ObservationIgnored private var recordedSerial: Int?

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
    /// **The Service in flight, held like a read** (ADR-0014 d.4): a shortcut, Escape or a newer Service cancels it.
    @ObservationIgnored private var serviceTask: Task<Void, Never>?
    /// The Service's origin rule, a seam for the tests; production reads XDict's own state (`ServiceOrigin.at`).
    @ObservationIgnored var serviceOrigin: @MainActor () -> ServiceOrigin = {
        ServiceOrigin.at(xdictActive: NSApplication.shared.isActive, xdictHasKeyWindow: NSApplication.shared.keyWindow != nil)
    }
    /// The selection read, shared by the shortcut and the Service's two paths, a seam for the tests; production reads
    /// through Accessibility (`SelectionReader`). A nil reader is no read.
    @ObservationIgnored var selectionRead: @MainActor @Sendable (FrontApp?, CGPoint?, HoverPolicy) async -> SelectionOutcome? = {
        reader, clicked, excluding in
        guard let reader else { return nil }
        return await SelectionReader.read(from: reader, clicked: clicked, excluding: excluding,
                                          ownHolder: LookupAnywhere.ownSelectionHolder)
    }
    /// Whether Accessibility is granted, a seam for the tests.
    @ObservationIgnored var isTrusted: @MainActor () -> Bool = { AXIsProcessTrusted() }
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
    @ObservationIgnored var lastOtherApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    /// Where the reader last right-clicked or Control-clicked, and when: where a Service request's selection is, when
    /// its app cannot say. A global mouse monitor, which needs no permission.
    /// Where and when a secondary click happened, and in which app: a Service reads its place only from a click in its
    /// own app. A value rather than a tuple of three, which SwiftLint refuses.
    struct SecondaryClick: Sendable {
        let point: CGPoint
        let at: Date
        let app: pid_t
    }

    @ObservationIgnored private var lastSecondaryClick: SecondaryClick?
    /// How recent a secondary click must be to anchor a Service: longer than the round trip through the Services menu, far
    /// shorter than a reader would take to forget clicking (a duration; audit-fix 2026-10-20 round 2, finding 8).
    static let serviceClickFreshness: TimeInterval = 15
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
            MainActor.assumeIsolated {
                self?.lastSecondaryClick = SecondaryClick(
                    point: point, at: Date(),
                    app: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? getpid())
            }
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
        NSApplication.shared.servicesProvider = ServicesProvider.shared
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
        // A new explicit trigger supersedes a Service still reading, and a read still reading (ADR-0014 d.4).
        serviceTask?.cancel()
        reading?.cancel()
        forgetGrantWaiter()
        // Escape cancels a read in flight, not only a shown panel (ADR-0014 d.4; CONTRACT.md §5.5).
        bindEscape()
        // **Numbered now, at the key**, before anything is read (ADR-0014 decision 4).
        pressed(as: requests.beginPresenting(.selection))
    }

    /// The shortcut or the menu, for `request`.
    private func pressed(as request: CaptureRequest) {
        // **A request superseded while it waited does nothing** (audit-fix 2026-10-20 finding 4): the menu waits 150 ms
        // after numbering, and its late side effects — cancelling the reads, painting a refusal — would land on the
        // request that superseded it.
        guard requests.isCurrent(request) else { return }
        let pressedAt = ContinuousClock.now
        let source = Source(request.trigger)
        observe?("pressed", ["request": request.number])
        guard let front = frontmostApp(), front.pid != getpid() || !isShown else {
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

    /// The app in front, a seam so a test can drive the shortcut and menu paths without a window server's answer.
    @ObservationIgnored var frontmostApp: @MainActor () -> FrontApp? = { FrontApp.frontmost() }

    /// **Escape, claimed while a read or the panel is in flight** — a seam, because the tests must never take the
    /// reader's Escape key: `escapeBind(true)` claims it for `close(why: "escape")`, `escapeBind(false)` gives it back.
    @ObservationIgnored var escapeBind: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private var escapeIsHeld = false
    /// **Which presentation is current**: `show` starts one, `close` ends one — a continuation after an await acts only
    /// for the presentation it began in (audit-fix 2026-10-20 round 2, finding 2).
    @ObservationIgnored private var presentation = 0

    /// Claims Escape once for work in flight; the panel's showing and a later read share the one claim.
    private func bindEscape() {
        guard !escapeIsHeld else { return }
        escapeIsHeld = true
        if let escapeBind { escapeBind(true); return }
        escape = HotkeyCenter.shared.escape.push { [weak self] in self?.close(why: "escape") }
    }

    /// Gives Escape back, whether or not anything was shown.
    private func releaseEscape() {
        guard escapeIsHeld else { return }
        escapeIsHeld = false
        if let escapeBind { escapeBind(false); return }
        if let escape { HotkeyCenter.shared.escape.pop(escape) }
        escape = nil
    }

    /// **A newer request supersedes a pending grant** (round 3, finding 3): what would be resumed is the request that
    /// asked for it, which is no longer current. A request that is itself asking sets its own waiter afterwards.
    private func forgetGrantWaiter() {
        gate.onGranted = nil
        polling?.cancel()
        polling = nil
    }

    @ObservationIgnored var gate = AccessibilityGate(check: AccessibilityGate.system)
    @ObservationIgnored private var polling: Task<Void, Never>?

    @ObservationIgnored private var poller = 0
    private func startPolling() {
        guard polling == nil else { return }
        poller += 1
        let mine = poller
        polling = Task { @MainActor [weak self] in
            while let gate = self?.gate, gate.isWaiting, !Task.isCancelled {
                try? await Task.sleep(for: AccessibilityGate.interval)
                guard !Task.isCancelled else { break }
                gate.poll()
            }
            // **Its own handle only** (round-2 verify): a cancelled poller's exit must not erase the one that replaced it.
            if let self, self.poller == mine { self.polling = nil }
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
        serviceTask?.cancel()
        bindEscape()
        let source = Source(request.trigger)
        // The reader's exclusions as they are at the key: they decide whether the sentence around the selection is read.
        let exclusions = hover.policy
        let selectionRead = selectionRead
        reading = Task { [weak self] in
            // The panel shows that it is reading if the read outlasts the grace; the answer replaces that. A request that
            // a newer one superseded never paints it (audit-fix 2026-10-20 finding 5): the waiting task outlives its read.
            let waiting = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.readGrace)
                guard let self, !Task.isCancelled, self.requests.isCurrent(request) else { return }
                self.show(.reading, query: nil, near: nil, source: source)
            }
            let outcome = await selectionRead(front, nil, exclusions) ?? .nothing(.notTrusted)
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
        // **A request that ended while it read paints nothing** (audit-fix 2026-10-20 finding 5): a newer request's
        // panel stands, and this read's refusal or failure is not shown over it.
        guard requests.terminal(of: request) == nil else { return }
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
        log.notice("selection answered in \(elapsed.components.attoseconds / 1_000_000_000_000_000 + elapsed.components.seconds * 1000) ms")
    }

    /// The Service: the text macOS handed over, looked up **by the selection** — its box where XDict may read it and
    /// it is the text handed over, else where the reader Control-clicked it (the pointer itself has moved on, into the
    /// Services submenu). Measured on the E2E Mac (2026-10-15): macOS brings the provider forward a moment after the
    /// request, so the reader's app — the last other app in front — is put back in front, and the panel's dismissal
    /// leaves it there with its next key. **A Service asked from one of XDict's own windows reads XDict's own
    /// selection** (owner, 2026-10-20), its sentence too, and puts no other app in front: whose request it is is decided
    /// now, as macOS hands the text over, by XDict's own state (`ServiceOrigin`), never by a click.
    func service(_ raw: String?) {
        // **Numbered now, as macOS hands the text over**, before the selection is read for its place.
        let request = requests.beginPresenting(.service)
        // A newer Service supersedes one in flight, as a shortcut or Escape does — and a shortcut's read with it, whose
        // late refusal would paint over this Service's panel (audit-fix 2026-10-20 finding 5).
        serviceTask?.cancel()
        reading?.cancel()
        // A grant still owed to an older request resumes nothing (round 3, finding 3).
        forgetGrantWaiter()
        // Escape cancels the Service while it reads, with no panel to dismiss yet (finding 2; CONTRACT.md §5.5).
        bindEscape()
        observe?("service", ["text": raw ?? NSNull(), "request": request.number])
        switch LookupText.term(raw) {
        case .term(let text):
            let previous = lastOtherApp
            observe?("serviceFront", ["xdictWasActive": NSApplication.shared.isActive, "previous": previous?.bundleIdentifier ?? NSNull()])
            let origin = serviceOrigin()
            // The click anchors a Service only where it was that Service's: a click in another app seconds ago is not this
            // request's place (finding 8).
            let wanted = origin == .ours ? getpid() : previous?.processIdentifier
            let clicked = lastSecondaryClick.flatMap {
                Date().timeIntervalSince($0.at) < Self.serviceClickFreshness && $0.app == wanted ? $0.point : nil
            }
            if origin == .ours {
                serviceFromOurWindow(text, request: request, clicked: clicked)
                return
            }
            // The click in Accessibility's coordinates (y down): the element there holds the selection where the
            // reader's app, back in front after the Services menu, names no focused one (Notes, TextEdit).
            let under = clicked.map { UpPoint($0).flipped(aboutPrimaryHeight: Self.primaryHeight) }
            serviceFromReadersApp(text, previous: previous, under: under, request: request)
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

    /// The Service asked from another app: back to that app, its selection read, delivered — **the cancellable
    /// acquisition in one place** (audit-fix 2026-10-20 findings 6 and 7). **Held like a read** (ADR-0014 d.4): cancelled
    /// by a shortcut, Escape or a newer Service, and the task checks before every side effect.
    private func serviceFromReadersApp(_ text: String, previous: NSRunningApplication?, under: DownPoint?,
                                       request: CaptureRequest) {
        serviceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Back to the reader's app first, and only then its selection read: an app that is not frontmost answers
            // for no focused element (TextEdit, Notes), and a host waits for the Service's answer before it answers
            // anything else.
            guard await self.bringForward(previous) else { self.requests.cancel(request); return }
            let read: SelectionOutcome?
            switch await self.serviceRead(previous.flatMap(FrontApp.resolving), under: under?.cg) {
            case .cancelled: self.requests.cancel(request); return
            case .read(let outcome): read = outcome
            }
            self.serviceDeliver(text, read: read, under: under, request: request,
                                source: SourceApp(bundleID: previous?.bundleIdentifier))
        }
    }

    /// The Service asked from one of XDict's own windows: XDict's own selection read for the box and the sentence — its
    /// entries by their own script, never Accessibility — and XDict left in front.
    private func serviceFromOurWindow(_ text: String, request: CaptureRequest, clicked: CGPoint?) {
        let under = clicked.map { UpPoint($0).flipped(aboutPrimaryHeight: Self.primaryHeight) }
        let ours = FrontApp(pid: getpid(), name: NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName,
                            bundleID: Bundle.main.bundleIdentifier)
        serviceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let read: SelectionOutcome?
            switch await self.serviceRead(ours, under: nil) {
            case .cancelled: self.requests.cancel(request); return
            case .read(let outcome): read = outcome
            }
            self.serviceDeliver(text, read: read, under: under, request: request,
                                source: SourceApp(bundleID: ours.bundleID))
        }
    }

    /// What reading a Service's selection for the box came to: the outcome (nil where XDict may not read at all), or
    /// cancellation — a read that answers after its request was cancelled changes nothing.
    private enum ServiceRead { case read(SelectionOutcome?), cancelled }

    /// **The selection read both Service origins share** — the trusted check, the read, its cancellation check and its
    /// observation (audit-fix 2026-10-20 finding 6). The Service's text is the query either way.
    private func serviceRead(_ app: FrontApp?, under: CGPoint?) async -> ServiceRead {
        // Cancelled before the task started (or between its steps): nothing is read, and nothing is delivered
        // (audit-fix 2026-10-20 verify: the untrusted branch returned before this check).
        guard !Task.isCancelled else { return .cancelled }
        guard isTrusted() else { return .read(nil) }
        let outcome = await selectionRead(app, under, hover.policy)
        guard !Task.isCancelled else { return .cancelled }
        observe?("serviceSelection", ["outcome": String(describing: outcome).prefix(300).description])
        return .read(outcome)
    }

    /// macOS brings the Service's provider forward a moment after the request: put the reader's app back in front before
    /// its selection is read (measured on the E2E Mac 2026-10-15). **False when cancelled**, checked after every sleep —
    /// a sleep interrupted by cancellation returns at once, so a check only at the loop's top would let a cancelled
    /// Service activate the reader's app (audit-fix 2026-10-20 finding 3).
    private func bringForward(_ previous: NSRunningApplication?) async -> Bool {
        for _ in 0..<12 {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return false }
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier == getpid() { previous?.activate() }
            if let previous, front == previous { break }
        }
        return !Task.isCancelled
    }

    /// **The Service's text is the query**, whatever the selection now says; the read supplies the box only where it
    /// agrees, else where the reader Control-clicked, as a word of no width (Chrome gives no box). One copy for both
    /// origins (audit-fix 2026-10-20 finding 6); a request ended meanwhile is refused by `present` itself.
    private func serviceDeliver(_ text: String, read: SelectionOutcome?, under: DownPoint?, request: CaptureRequest,
                                source: SourceApp) {
        do {
            let term = try SelectionReader.serviceTerm(text, read: read, source: source, clicked: under)
            _ = requests.present(term, for: request, to: self)
        } catch {
            // **A request that already ended paints nothing** — its Service was dismissed or superseded, and the reason
            // its text could not become a term is not a panel over what replaced it (audit-fix 2026-10-20 verify).
            guard requests.terminal(of: request) == nil else { return }
            requests.cancel(request)
            show(.refused(.noWord(app: "")), query: nil, near: nil, source: .service)
        }
    }

    /// The menu-bar item's Look Up Selection: as the shortcut — numbered at the click — once the menu has closed and the
    /// reader's app is in front again.
    func lookUpFromMenu() {
        let request = requests.beginPresenting(.menu)
        forgetGrantWaiter()
        bindEscape()
        observe?("menu", ["request": request.number])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.pressed(as: request)
        }
    }

    // MARK: - Capture's sink

    /// A term presented for its request: shown in the popover, the term alone to search, its context to the session.
    private func accept(_ delivery: CaptureDelivery) -> CaptureDeliveryAnswer {
        guard let state else { return .refused }
        let term = delivery.term
        contextSession.hold(term, request: delivery.request.number, generation: delivery.generation)
        // **The AI pane's one source of the sentence** (ADR-0021 d.4; `conformance/capture/CONTRACT.md` §6): held for this
        // presentation only, and only when the capture has one — an ask with no sentence is not an "in context" ask. The
        // context read itself lives in `MeaningHandoffFromTerm.swift`, the one file the privacy guard admits.
        if let handoff = MeaningHandoff(term: term, origin: MeaningOrigin(
            request: delivery.request.number, generation: delivery.generation)) {
            state.holdMeaning(handoff)
        } else {
            state.clearMeaning()
        }
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
        presentation += 1
        // **Every presentation that is not a delivery drops the previous sentence** (CONTRACT.md §6): a refusal or the
        // "reading" panel replaces what was presented, and the session holds one context at a time (finding 5).
        if notice != .none {
            contextSession.clear()
            state.clearMeaning()
        }
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
        bindEscape()
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
        // A document finished in the popover: the presented term's only where it is the document the window asked to
        // show for the lookup shown now (plan-capture WI-4 rule 3) — a stale document's finish in the gap before a newer
        // lookup's entry request is not a draw of the newer term.
        if state?.showsPresentedLookup == true { drew(query: state?.model.lookup?.query) }
        recordReadingIfDrawn()
        shownEntry += 1
        fit.began(entry: shownEntry)
        let entry = shownEntry
        Task { @MainActor in
            // **The schedule is measured from the finish** (audit round 4, 2026-10-26): sleeping each interval in turn
            // measured at 0.4, 1.6 and 4.6 seconds, not the 0.4, 1.2 and 3 the comment promised.
            var waited: Duration = .zero
            for delay in [Duration.zero, .milliseconds(400), .milliseconds(1200), .milliseconds(3000)] {
                let wait = delay - waited
                if wait > .zero { try? await Task.sleep(for: wait) }
                waited = delay
                guard entry == self.shownEntry else { return }
                await self.fitToEntry(entry)
            }
        }
    }

    /// **Only an entry that actually drew is recorded** (plan-history-and-learning §2.2): the finished document belongs
    /// to the lookup shown now, an entry exists (not a no-results placeholder), a sentence was captured, and the panel is
    /// on screen. A closed panel, a no-results lookup and a stale completion each record nothing; `HistoryModel.record`
    /// adds the reader's switch, so off writes no bytes at all. One finish records once per shown entry: the entry view
    /// can report a document more than once.
    private func recordReadingIfDrawn() {
        guard let state else { return }
        let capture = HistoryCapture(onScreen: panel?.isShown == true, current: state.showsPresentedLookup,
                                     hasEntry: state.hasEntry, hasSentence: state.meaning.held != nil)
        guard capture.records, let shown = state.model.shown, let handoff = state.meaning.held,
              recordedSerial != shown.serial else { return }
        recordedSerial = shown.serial
        let dictionary = state.library.entries.first { $0.id == shown.result.dictionary }
        let reading = ReadingCapture.reading(handoff: handoff, entry: shown.result.entry, dictionary: dictionary,
                                             at: Date(), device: DeviceIdentity.current())
        Task { await XDictApp.history.record(reading) }
    }

    /// **A phrase row appearing or leaving re-fits the panel** (audit round 4, 2026-10-26): the fit follows a document's
    /// finish, and the capture's row arrives later — without this the entry keeps the room the row now needs.
    func phraseRowChanged() {
        guard let state, state.model.shown != nil, panel?.isShown == true else { return }
        shownEntry += 1
        fit.began(entry: shownEntry)
        let entry = shownEntry
        Task { @MainActor in await self.fitToEntry(entry) }
    }

    /// The panel as tall as its entry, within bounds and the screen's room (UI review P-03, Codex §3), its top edge
    /// kept where it is unless that would leave the screen.
    private func fitToEntry(_ entry: Int) async {
        guard let state else { return }
        let document = await state.entry.documentHeight()
        guard let panel, panel.isShown else { return }
        let visible = (panel.anchor.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let height = PanelPlacement.height(document: document,
                                           chrome: LookupPanelView.chromeHeight(for: state.phrases.row),
                                           available: visible.height - 2 * PanelPlacement.margin)
        guard fit.accepts(height: height, current: panel.bodySize.height, entry: entry) else { return }
        panel.resize(height: height)
    }

    func close(why: String) {
        reading?.cancel()
        serviceTask?.cancel()
        // **A grant arriving after the dismissal must not resurrect it** (finding 1): nothing waits to be resumed, and
        // the poller stops instead of calling a dismissed lookup back.
        polling?.cancel()
        polling = nil
        gate.onGranted = nil
        presentation += 1
        // **Closing supersedes every request so far** (ADR-0014 decision 4): each still open ends cancelled, a late result
        // is not presented over the dismissal, and the presented request's context goes with the panel (decision 9).
        requests.close()
        contextSession.clear()
        state?.clearMeaning()
        acks.closed()
        drawnQuery = nil
        // A read in flight holds Escape with no panel to close (audit-fix 2026-10-20 finding 2): the claim is given back
        // whether or not anything was shown, and a close with neither still returns without an event.
        let shown = panel?.isShown == true
        guard shown || escapeIsHeld else { return }
        panel?.close()
        releaseEscape()
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors = []
        observe?("closed", ["why": why])
    }

    /// A click anywhere but the panel closes it: a global monitor for other apps' clicks (mouse events need no
    /// permission), a local one for XDict's own windows — whose event is returned, never swallowed. A click in the
    /// panel's own pop-up menu is the panel's.
    ///
    /// **The release of the click, not its press** (2026-10-21): closing on the press removed the panel's window while
    /// the reader's click was still in flight, and a text view that took that click never completed it — the next key
    /// went nowhere until another click (the E2E's click-away check, reproduced by hand: TextEdit's selection moved,
    /// its 72 characters stayed, and three q's in a row were lost). A press is not a click until it is let go.
    private func watchForClicksAway() {
        guard clickMonitors.isEmpty else { return }
        let kinds: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
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
    /// **Expanded into a main window**; with `asking`, the window also asks the reader's chosen source at once (the
    /// popover's "Meaning here", ADR-0021 d.1: the panel is too small to answer in).
    func expand(asking: Bool = false) {
        guard let state else { return }
        let mine = presentation
        // **The sentence travels with the expansion** (ADR-0021 d.4): captured here, while the presentation still holds
        // it, and handed to the window the place goes to — never stored in the trail (`Visit` is stored; this is not).
        let meaning = state.meaning.held
        // **The lookup the expansion belongs to** (audit round 4, 2026-10-26): a newer request changes the model's lookup
        // before its own `show()`, so `presentation` alone let this continuation close the panel and cancel the newer
        // lookup while the reader was still being served.
        let lookup = state.model.lookup?.serial
        Task { @MainActor [weak self] in
            let place = await state.model.currentPlace()
            // **Dismissed or replaced while the place was read** (finding 2): the continuation closes nothing and
            // activates nothing — the reader's Escape stands.
            guard let self, self.presentation == mine, self.isShown, state.model.lookup?.serial == lookup else { return }
            guard let place else {
                if let query = state.model.lookup?.query { MainWindows.hand(Visit(query: query, mode: .reader, scope: .all,
                                                                                  isOrigin: true), meaning: meaning,
                                                                            asking: asking) }
                self.finishExpanding(nil)
                return
            }
            MainWindows.hand(place, meaning: meaning, asking: asking)
            self.finishExpanding(place)
        }
    }

    private func finishExpanding(_ place: Visit?) {
        close(why: "expanded")
        NSApplication.shared.activate()
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
                        },
                        askMeaning: { anywhere.expand(asking: true) })
            .onChange(of: state.placeholder) { _, placeholder in anywhere.placeholderChanged(placeholder) }
            // **The lookup itself, not only its placeholder** (round 3, finding 4): an empty library's "No dictionaries."
            // is the same value for every query, so a delivered request settled to it never fired the observer above.
            .onChange(of: state.model.lookup) { _, _ in anywhere.placeholderChanged(state.placeholder) }
            // **The phrase row changes what the panel is**: it appears after the capture, outside a document's finish.
            .onChange(of: state.phrases.row) { _, _ in anywhere.phraseRowChanged() }
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
    /// The sentence that travels with `pending` (ADR-0021 d.4): handed to the window's presentation explicitly, once.
    private static var pendingMeaning: MeaningHandoff?
    /// Whether the window should ask as soon as it holds that sentence: the popover's "Meaning here" (ADR-0021 d.1).
    private static var pendingAsk = false

    private struct WeakState { weak var state: SearchWindowState? }

    static func made(_ state: SearchWindowState) {
        states.removeAll { $0.state == nil }
        states.append(WeakState(state: state))
        if pending != nil { _ = deliver() }
    }

    static func hand(_ place: Visit, meaning: MeaningHandoff? = nil, asking: Bool = false) {
        pending = place
        pendingMeaning = meaning
        pendingAsk = asking && meaning != nil
    }

    /// Gives the pending place to the most recent main window still open, and brings that window forward; false when
    /// there is none.
    static func deliver() -> Bool {
        states.removeAll { $0.state == nil }
        guard let place = pending else { return false }
        // **One window adopts the place and comes forward** (audit round 4, 2026-10-26): the place went to the last state
        // made while the first visible window was activated, so with two windows open a lookup landed behind the
        // reader's back. The frontmost window that is open is the one that takes it.
        let open = states.compactMap { entry -> (SearchWindowState, NSWindow)? in
            guard let state = entry.state, let window = state.entry.view.window else { return nil }
            return (state, window)
        }
        let chosen = open.first { $0.1.isKeyWindow } ?? open.first { $0.1.isMainWindow } ?? open.first { $0.1.isVisible }
            ?? open.last
        guard let (state, window) = chosen else { return false }
        pending = nil
        let meaning = pendingMeaning
        let ask = pendingAsk
        pendingMeaning = nil
        pendingAsk = false
        if let meaning {
            // Asking waits for the adopted entry, named here so a stale presentation's draw cannot satisfy it; a
            // hand-off with no sentence drops the last one, so an expansion never asks about an older presentation.
            let expected = place.result.map {
                MeaningSession.Subject(dictionary: $0.dictionary, key: $0.entry.key,
                                       occurrence: $0.entry.occurrence)
            }
            state.holdMeaning(meaning, asking: ask, expecting: expected, adopted: true)
            // **The adoption reports its own lookup, for this hand-off only**: a callback from an adoption a newer
            // hand-off superseded cannot name the lookup that may bind the sentence now held.
            let token = state.meaning.handoffToken
            state.model.adopt(place, started: { serial in state.meaning.adopted(serial, handoff: token) })
        } else {
            state.clearMeaning()
            state.model.adopt(place)
        }
        state.focusSearch()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// The main window holding a state, and what it shows: for the instruments.
    static var front: SearchWindowState? { states.last { $0.state != nil }?.state }
}

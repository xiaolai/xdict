import AppKit
import ApplicationServices
import Observation
import SwiftUI
import XDictAnywhere
import XDictBase
import XDictContract
import XDictEntryView
import XDictSearch
import XDictUI
import os

/// **Lookup from anywhere** (plan-macos-v1 WI-8): a selection in any app reaches a panel by it — by the lookup shortcut
/// (the selection read through the Accessibility API), by the Service "Look Up in XDict" (the text macOS hands over), or
/// by the menu-bar item — and the panel expands into the main window keeping query, dictionary and scroll (I5).
/// Dismissal by Escape or a click elsewhere leaves the reader's app in front, its next key reaching it (I6): **the panel
/// never activates XDict and never becomes key**.
@MainActor
@Observable
final class LookupAnywhere {
    /// Where a lookup came from: what the instruments record, and what places the panel.
    enum Source: String { case shortcut, service, menu }

    static let shared = LookupAnywhere()

    /// How long the selection may take before the panel shows by the pointer, saying it is reading: the panel's budget is
    /// 1 s from the key (the E2E `panel.deadline` sub-stage), and a hung app may take the read's whole 2 s.
    static let readGrace: Duration = .milliseconds(300)
    static let panelSize = CGSize(width: 460, height: 440)

    @ObservationIgnored private(set) lazy var registrar = ShortcutRegistrar(
        defaults: .standard, hotkeys: .shared) { [weak self] in self?.pressed() }
    private(set) var notice = PanelNotice.none
    /// The panel's own search and entry view: made once, at launch, so the first lookup does not wait for a web view.
    @ObservationIgnored private var state: SearchWindowState?
    @ObservationIgnored private var panel: LookupPanelWindow?
    @ObservationIgnored private var escape: EscapeStack.Entry?
    @ObservationIgnored private var clickMonitors: [Any] = []
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: XDictIdentity.app, category: "anywhere")
    /// Opens a main window: set by the scene, which alone holds SwiftUI's `openWindow`.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// What the panel and the expansion did, for the instruments (`AnywhereReport`).
    @ObservationIgnored var observe: ((String, [String: Any]) -> Void)?

    var isShown: Bool { panel?.isVisible == true }
    var panelState: SearchWindowState? { state }
    var panelFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

    /// Registers the shortcut, offers the Service, and readies the panel. Once, at launch.
    /// The last app other than XDict to be frontmost: where a Service request came from, when it brought XDict forward.
    @ObservationIgnored private var lastOtherApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    /// Where the reader last right-clicked or Control-clicked, and when: where a Service request's selection is, when
    /// its app cannot say. A global mouse monitor, which needs no permission.
    @ObservationIgnored private var lastSecondaryClick: (point: CGPoint, at: Date)?
    @ObservationIgnored private var secondaryClickMonitor: Any?

    func start() {
        guard state == nil else { return }
        lastOtherApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
        secondaryClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return }
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.lastSecondaryClick = (point, Date()) }
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
        state = XDictApp.windowState()
    }

    // MARK: - Asking

    /// The shortcut: the selection of the app in front, or — with the panel showing that very lookup — expansion, the
    /// panel's keyboard route (it takes no keys of its own).
    func pressed() {
        let pressedAt = ContinuousClock.now
        observe?("pressed", [:])
        guard let front = FrontApp.frontmost(), front.pid != getpid() || !isShown else {
            if isShown { expand() } else { show(.refused(.noApp), query: nil, near: nil, source: .shortcut) }
            return
        }
        // No grant: the system's own request, once; the panel says what to do; the grant resumes this lookup.
        switch gate.request() {
        case .trusted:
            break
        case .asked, .waiting:
            gate.onGranted = { [weak self] in self?.resume(front) }
            startPolling()
            show(.refused(.notTrusted), query: nil, near: nil, source: .shortcut)
            return
        }
        read(front, pressedAt: pressedAt)
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

    /// The grant arrived while the request was open: the lookup that found none, carried on.
    private func resume(_ front: FrontApp) {
        observe?("granted", [:])
        guard NSRunningApplication(processIdentifier: front.pid) != nil else { return }
        read(front, pressedAt: .now)
    }

    private func read(_ front: FrontApp, pressedAt: ContinuousClock.Instant) {
        reading?.cancel()
        reading = Task { [weak self] in
            // The panel shows that it is reading if the read outlasts the grace; the answer replaces that.
            let waiting = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.readGrace)
                guard !Task.isCancelled else { return }
                self?.show(.reading, query: nil, near: nil, source: .shortcut)
            }
            let outcome = await SelectionReader.read(from: front)
            waiting.cancel()
            guard let self, !Task.isCancelled else { return }
            self.answer(outcome, pressedAt: pressedAt)
        }
    }

    private func answer(_ outcome: SelectionOutcome, pressedAt: ContinuousClock.Instant) {
        switch outcome {
        case .selected(let selected, let box):
            if isShown, notice == .none, state?.model.lookup?.query == selected.text {
                expand()  // the same selection again: the keyboard route to the main window
                return
            }
            show(.none, query: selected.text, near: box.map { PanelPlacement.flipped($0.rect, primaryHeight: Self.primaryHeight) },
                 source: .shortcut)
        case .nothing(let refusal):
            show(.refused(refusal), query: nil, near: nil, source: .shortcut)
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
        observe?("service", ["text": raw ?? NSNull()])
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
                var word: CGRect?
                if AXIsProcessTrusted(), let reader = previous.flatMap(FrontApp.resolving), reader.pid != getpid() {
                    let outcome = await SelectionReader.read(from: reader)
                    self.observe?("serviceSelection", ["outcome": String(describing: outcome).prefix(300).description])
                    if case .selected(let selected, let box?) = outcome, selected.text == text {
                        word = PanelPlacement.flipped(box.rect, primaryHeight: Self.primaryHeight)
                    }
                }
                // No box (Chrome gives none): where the reader Control-clicked the selection, as a word of no width.
                if word == nil, let clicked { word = CGRect(x: clicked.x, y: clicked.y - 8, width: 1, height: 16) }
                self.show(.none, query: text, near: word, source: .service)
            }
        case .empty: show(.refused(.nothingSelected(app: "")), query: nil, near: nil, source: .service)
        case .noWord: show(.refused(.noWord(app: "")), query: nil, near: nil, source: .service)
        case .tooLong(let characters): show(.refused(.tooLong(app: "", characters: characters)), query: nil, near: nil,
                                            source: .service)
        }
    }

    /// The menu-bar item's Look Up Selection: as the shortcut, once the menu has closed and the reader's app is in front
    /// again.
    func lookUpFromMenu() {
        observe?("menu", [:])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            self.pressed()
        }
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
        let frame = PanelPlacement.frame(size: Self.panelSize, word: word, pointer: pointer,
                                         visible: screen?.visibleFrame ?? CGRect(origin: .zero, size: Self.panelSize))
        if !panel.isVisible || notice != .reading { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
        if escape == nil {
            escape = HotkeyCenter.shared.escape.push { [weak self] in self?.close(why: "escape") }
        }
        watchForClicksAway()
        observe?("shown", ["source": source.rawValue, "query": query ?? NSNull(), "frame": Self.describe(frame),
                           "word": word.map(Self.describe) ?? NSNull(), "notice": String(describing: notice)])
    }

    private func makePanel(_ state: SearchWindowState) -> LookupPanelWindow {
        let panel = LookupPanelWindow(contentRect: CGRect(origin: .zero, size: Self.panelSize))
        panel.contentView = NSHostingView(rootView: PanelRoot(anywhere: self, state: state))
        self.panel = panel
        return panel
    }

    func close(why: String) {
        reading?.cancel()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
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
        guard let panel, panel.isVisible else { return }
        if window === panel || panel.frame.contains(point) { return }
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

/// **The panel's window**: a non-activating panel that never becomes key or main — so the reader's app keeps the
/// keyboard and its next key — floating above ordinary windows, joining every Space and full-screen app, as a Quick
/// Look or Dictionary panel does. Borderless chrome is not used: a titled utility panel draws the standard close button
/// and shadow, and moves by its title bar.
final class LookupPanelWindow: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel,
                                                         .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        setAccessibilityIdentifier("lookupPanel")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The close button, like Escape and a click away.
    override func performClose(_ sender: Any?) {
        MainActor.assumeIsolated { LookupAnywhere.shared.close(why: "closeButton") }
    }
}

/// The panel's SwiftUI root: the content, redrawn as the notice and the shortcut change.
private struct PanelRoot: View {
    let anywhere: LookupAnywhere
    let state: SearchWindowState

    var body: some View {
        LookupPanelView(state: state, notice: anywhere.notice,
                        shortcut: anywhere.registrar.isRegistered ? anywhere.registrar.current.label() : nil) {
            anywhere.expand()
        }
        .padding(.top, 20)  // under the transparent title bar's close button
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

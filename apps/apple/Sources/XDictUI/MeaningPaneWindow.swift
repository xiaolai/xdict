import AppKit
import SwiftUI
import XDictTokens

/// **The answer pane as its own window beside the reading area** (owner, 2026-10-24): the main window keeps SwiftUI's
/// `.searchable` at its trailing edge, so the pane cannot live inside that window without the search sitting above the
/// pane. The pane is an attached child window instead: full height, its toggle at its top-left, outside the main
/// window, which keeps its own frame and its search in the main area.
struct MeaningPaneWindow: NSViewRepresentable {
    let shown: Bool
    let width: CGFloat
    @Binding var presentation: MeaningPlacement
    let state: SearchWindowState

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.shown = shown
        probe.paneWidth = width
        probe.changed = { presentation = $0 }
        probe.state = state
        probe.schedule()
    }

    /// Where the pane goes: full height against the main window's trailing edge, or nil when the screen has no room
    /// (the sheet takes over then). The main window's own frame never changes.
    struct Layout {
        static func frame(main: NSRect, screen: NSRect, width: CGFloat) -> NSRect? {
            // **A little apart from the main window** (owner, 2026-10-24): the pane reads as its own surface.
            let frame = NSRect(x: main.maxX + MeaningPanePreferences.gap(), y: main.minY, width: width,
                               height: main.height)
            guard width > 0, frame.maxX <= screen.maxX, frame.minY >= screen.minY,
                  frame.maxY <= screen.maxY else { return nil }
            return frame
        }
    }

    @MainActor
    final class Probe: NSView {
        var shown = false
        var paneWidth = Tokens.Window.meaningPaneIdeal
        var changed: ((MeaningPlacement) -> Void)?
        var state: SearchWindowState?

        private var controller: PaneController?
        private var presented: MeaningPlacement = .hidden
        private var pending = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                             NSWindow.didMoveNotification, NSWindow.didEnterFullScreenNotification,
                             NSWindow.didExitFullScreenNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowChanged),
                                                           name: name, object: window)
                }
            } else {
                closePane()
            }
            schedule()
        }

        @objc private func windowChanged(_ notification: Notification) { schedule() }

        func schedule() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                self.apply()
            }
        }

        private func apply() {
            guard let main = window, shown else {
                closePane()
                if presented != .hidden {
                    presented = .hidden
                    changed?(.hidden)
                }
                return
            }
            if main.styleMask.contains(.fullScreen) {
                closePane()
                settle(.sheet)
                return
            }
            let screen = main.screen?.visibleFrame ?? main.frame
            guard let frame = Layout.frame(main: main.frame, screen: screen, width: paneWidth),
                  let state else {
                closePane()
                settle(.sheet)
                return
            }
            let controller = self.controller ?? PaneController(state: state) { [weak self] in
                self?.readerClosed()
            }
            self.controller = controller
            controller.show(asChildOf: main, target: frame)
            settle(.window)
        }

        private func settle(_ place: MeaningPlacement) {
            guard presented != place else { return }
            presented = place
            changed?(place)
        }

        private func closePane() {
            guard let controller else { return }
            controller.animateOut { [weak self] in
                if self?.controller === controller { self?.controller = nil }
            }
        }

        /// The pane window's own close button: the reader closed the answer.
        private func readerClosed() {
            controller = nil
            presented = .hidden
            changed?(.hidden)
            state?.panes.meaningClosed(by: .window, current: .window)
            state?.panes.examplesClosed()
        }
    }
}

/// A borderless window that can take the keyboard, so the pane's text selects and scrolls.
@MainActor
final class PaneWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The pane window: a titleless child window beside the main one, its answer with no top area of its own. It opens like
/// a drawer — the width grows out of the main window's trailing edge over the reader's opening time (Settings ▸ General,
/// 0.5 s by default; Off opens it at once, and so does Reduce Motion) — and **closing is immediate** (owner, 2026-10-24).
@MainActor
final class PaneController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private var closingProgrammatically = false
    /// An opening animation is running: later layout passes must not set the frame and cancel it.
    private var opening = false
    /// The pane's view, held at its final size while the window grows (owner, 2026-10-24: the text must not move with
    /// the reveal). The window only reveals it; the content itself is still.
    private let hostView: NSHostingView<PaneContent>
    /// The question group's toolbar, kept for the window's life.
    private let toolbar: PaneToolbar

    init(state: SearchWindowState, onClose: @escaping () -> Void) {
        self.onClose = onClose
        // **A titlebar-less window with a real toolbar** (owner, 2026-10-26: the pane's question buttons must be the
        // main window's nav pair itself, not a control imitating it): full-size content under an invisible titlebar, and
        // the traffic lights hidden by hand — SwiftUI has no API for that, and no control outside a toolbar can be the
        // toolbar item's 36 pt with its scaled glyph (measured: a ControlGroup is 28, AppKit's large segmented control 24).
        let window = PaneWindow(contentRect: NSRect(x: 0, y: 0, width: Tokens.Window.meaningPaneIdeal, height: Tokens.Window.paneInitialHeight),
                                styleMask: [.titled, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: true)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        let toolbar = NSToolbar(identifier: "ai.xdict.app.meaningPane")
        let modes = PaneToolbar(state: state)
        toolbar.delegate = modes
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        self.toolbar = modes
        // **The window's own surface, corners and shadow** (owner, 2026-10-26, after the toolbar's buttons drew over
        // nothing at the pane's top edge): a titled window carries its toolbar band, its rounded corners and its shadow
        // itself, so the pane's surface reaches under the toolbar. The content no longer paints a shape of its own.
        window.collectionBehavior = [.transient, .ignoresCycle]
        // **A hosting view that follows the window by autoresizing**: a content view controller's Auto Layout
        // re-imposes its fitting width every frame and cancels the drawer animation.
        let host = NSHostingView(rootView: PaneContent(state: state))
        hostView = host
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = []
        host.frame = NSRect(origin: .zero, size: window.frame.size)
        // **The window is a mask over a still pane** (owner, 2026-10-24): the content keeps its final size and position
        // from the first frame; the growing window reveals it, so the text never reflows or slides.
        let content = NSView()
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.addSubview(host)
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.hasShadow = true
        // The drawer grows from a sliver of width: the content's least must not stop it.
        window.contentMinSize = .zero
        window.minSize = .zero
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The drawer's opening: the window starts with no width at the main window's edge and grows to `target`.
    func show(asChildOf main: NSWindow, target: NSRect) {
        guard let window, !opening else { return }
        if window.isVisible {
            window.setFrame(target, display: true)
            hostView.frame = window.contentView?.bounds ?? hostView.frame
            hostView.autoresizingMask = [.width, .height]
            window.invalidateShadow()
            return
        }
        hostView.frame = NSRect(origin: .zero, size: target.size)
        hostView.autoresizingMask = []
        // **Shut before it is in the window, then grown** (type-review's `KeyboardDrawer`): appearing at full size and
        // then animating would show the finished state for one frame first. One point, not zero — AppKit does not
        // animate a zero-size window.
        window.setFrame(NSRect(x: target.minX, y: target.minY, width: Tokens.Window.drawerShutWidth, height: target.height), display: false)
        if window.parent == nil { main.addChildWindow(window, ordered: .above) }
        window.orderFront(nil)
        window.invalidateShadow()
        opening = true
        // The opening time is the reader's (owner, 2026-10-24); zero opens it at once, and Reduce Motion does too.
        let duration = MeaningPanePreferences.animation()
        guard duration > 0.01,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(target, display: true)
            finishOpening(window)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            // AppKit calls this completion on the main thread; the hop is what the isolation checker needs.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.finishOpening(window)
            }
        }
    }

    /// **The pane's content measures its final width now** (owner, 2026-10-24): the drawer's last frame must be a
    /// layout, or the content stays at the width it held mid-animation and leaves the right side empty.
    private func finishOpening(_ window: NSWindow) {
        opening = false
        hostView.frame = window.contentView?.bounds ?? hostView.frame
        hostView.autoresizingMask = [.width, .height]
        hostView.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.invalidateShadow()
    }

    /// Closing is immediate (owner, 2026-10-24): the pane simply goes.
    func animateOut(completion: @escaping () -> Void) {
        if let window {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
        completion()
    }

    func closeProgrammatically() {
        closingProgrammatically = true
        close()
        closingProgrammatically = false
    }

    func windowWillClose(_ notification: Notification) {
        guard !closingProgrammatically else { return }
        onClose()
    }
}

/// **The pane's one toolbar item: the question group, drawn by the toolbar itself** (owner, 2026-10-26): an
/// `NSToolbarItemGroup` in selection mode, which is the system's own segmented group inside a toolbar — the same
/// drawing the main window's Back/Forward pair gets, sized by the toolbar. A hosted SwiftUI view was measured at 28 pt
/// inside the same item; the group is the toolbar's own.
@MainActor
final class PaneToolbar: NSObject, NSToolbarDelegate {
    static let modes = NSToolbarItem.Identifier("meaning.modes")
    private let state: SearchWindowState

    init(state: SearchWindowState) { self.state = state }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.modes] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.modes] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.modes else { return nil }
        let modes = MeaningAskMode.allCases
        let images = modes.compactMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.labelText) }
        let group = NSToolbarItemGroup(itemIdentifier: identifier, images: images, selectionMode: .selectOne,
                                       labels: modes.map(\.labelText), target: self,
                                       action: #selector(chosen(_:)))
        group.label = String(localized: "Question")
        group.paletteLabel = String(localized: "Question")
        group.selectedIndex = modes.firstIndex(of: state.meaning.chosenMode) ?? 0
        for (index, each) in modes.enumerated() {
            group.subitems[index].toolTip = each.helpText
        }
        return group
    }

    /// The reader pressed a segment: the question it stands for is asked.
    @objc private func chosen(_ sender: NSToolbarItemGroup) {
        let modes = MeaningAskMode.allCases
        let index = sender.selectedIndex
        guard index >= 0, index < modes.count else { return }
        state.chooseMeaningMode(modes[index])
    }
}

/// The pane's content: the answer alone, no title-and-source header; ⌘I toggles the pane.
private struct PaneContent: View {
    let state: SearchWindowState

    var body: some View {
        MeaningAnswerPane(state: state, showsHeader: false)
            // **⌘I works while the pane has the keyboard too**: the menu command reads this window's focused value.
            .focusedSceneValue(\.searchWindow, state)
    }
}

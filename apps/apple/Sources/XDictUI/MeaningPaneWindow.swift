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
/// a drawer — the width grows out of the main window's trailing edge over `drawerDuration` (owner, 2026-10-24: 0.5 s),
/// or instantly when the reader has reduce motion on — and **closing is immediate** (owner, 2026-10-24).
@MainActor
final class PaneController: NSWindowController, NSWindowDelegate {
    static let drawerDuration: TimeInterval = 0.5
    private let onClose: () -> Void
    private var closingProgrammatically = false
    /// An opening animation is running: later layout passes must not set the frame and cancel it.
    private var opening = false
    /// The pane's view, held at its final size while the window grows (owner, 2026-10-24: the text must not move with
    /// the reveal). The window only reveals it; the content itself is still.
    private let hostView: NSHostingView<PaneContent>

    init(state: SearchWindowState, onClose: @escaping () -> Void) {
        self.onClose = onClose
        // **Borderless, like type-review's `KeyboardDrawer`** (owner, 2026-10-24: "learn from ../type-review-macOS"):
        // no titlebar at all, and its rule of a shut size of one point, ordered in shut and then grown.
        let window = PaneWindow(contentRect: NSRect(x: 0, y: 0, width: Tokens.Window.meaningPaneIdeal, height: Tokens.Window.paneInitialHeight),
                                styleMask: [.borderless, .resizable],
                                backing: .buffered, defer: true)
        // **The window's shape is its content's** (type-review's `KeyboardDrawer`, measured there): a transparent
        // borderless window's shadow follows the alpha of what it draws, so the pane's rounded, opaque surface carries
        // the rounded corners and the shadow together. The shape is cached: `invalidateShadow` after every change.
        window.isOpaque = false
        window.backgroundColor = .clear
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
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0 : Self.drawerDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.opening = false
            self.hostView.frame = window.contentView?.bounds ?? self.hostView.frame
            self.hostView.autoresizingMask = [.width, .height]
            // **The pane's content measures its final width now** (owner, 2026-10-24): the drawer's last frame must be
            // a layout, or the content stays at the width it held mid-animation and leaves the right side empty.
            self.hostView.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.invalidateShadow()
        }
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

/// The pane's content: the answer alone, no title-and-source header; ⌘I toggles the pane.
private struct PaneContent: View {
    let state: SearchWindowState

    var body: some View {
        MeaningAnswerPane(state: state, showsHeader: false)
            // **The pane's own surface** (owner, 2026-10-24): rounded like the reader's windows, opaque so the
            // transparent window's shadow follows this shape, and nothing else above the answer.
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Window.drawerCornerRadius, style: .continuous))
            // **⌘I works while the pane has the keyboard too**: the menu command reads this window's focused value.
            .focusedSceneValue(\.searchWindow, state)
    }
}

import AppKit
import Observation
import SwiftUI
import XDictTokens

/// **Where the docked drawer sits** (ported from XiaolaiDict's `DrawerGeometry`, plan-history-and-learning §1): the right
/// edge of the display the menu-bar item is on, the full visible height, flush, with the corners against that edge
/// square and the others at macOS 27's own window corner. Pure arithmetic, so a small screen, a Dock on the right and a
/// drawer wider than the display are tests rather than looks.
public struct HistoryDrawerGeometry: Equatable, Sendable {
    /// The window's frame in AppKit screen coordinates: the drawer grown by the shadow margin for the glass's shadow to
    /// land in, then clipped to the display, so a drawer beside another display casts nothing onto it.
    public let window: CGRect
    /// The drawer itself, in the display's coordinates.
    public let content: CGRect
    /// The drawer's top-left corner inside the window, in SwiftUI's coordinates (y down).
    public let contentOrigin: CGPoint
    /// Added to `contentOrigin`, this parks the drawer wholly past the window's docked edge: the window's clip hides it.
    public let hiddenOffset: CGSize
    public let cornerRadius: CGFloat
    /// The drawer reaches the display's own edge — not merely the visible frame's, which stops short when the Dock is on
    /// that side. Only then do its trailing corners stay square.
    public let isFlush: Bool
    /// Under a point is rounding, not a gap.
    public static let edgeTolerance = Tokens.Window.drawerEdgeTolerance

    public var squaresTrailingCorners: Bool { isFlush }

    public static func make(width: CGFloat, visible: CGRect, screen: CGRect, cornerRadius: CGFloat,
                            shadowMargin: CGFloat) -> HistoryDrawerGeometry {
        // Clamped with no floor: a minimum would make a drawer wider than a display narrower than it.
        let thickness = min(max(width, 0), max(0, visible.width))
        let content = CGRect(x: visible.maxX - thickness, y: visible.minY, width: thickness, height: visible.height)
        let grown = content.insetBy(dx: -shadowMargin, dy: -shadowMargin)
        let clipped = grown.intersection(screen)
        let window = clipped.isNull ? content : clipped
        let originX = content.minX - window.minX
        let originY = window.maxY - content.maxY
        let flush = visible.maxX >= screen.maxX - edgeTolerance
        return HistoryDrawerGeometry(window: window, content: content,
                                     contentOrigin: CGPoint(x: originX, y: originY),
                                     hiddenOffset: CGSize(width: window.width - originX, height: 0),
                                     cornerRadius: cornerRadius, isFlush: flush)
    }

    /// The drawer's shape: the trailing corners square while it is flush with the display's edge, as system panels do.
    public var shape: UnevenRoundedRectangle {
        let r = cornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: r, bottomLeadingRadius: r,
            bottomTrailingRadius: squaresTrailingCorners ? 0 : r, topTrailingRadius: squaresTrailingCorners ? 0 : r,
            style: .continuous)
    }
}

/// **What the drawer's view reads**: where it is, and whether it has slid in. An observable pair, because the window is
/// placed once at its docked rect and only the content moves — animating a window's frame relayouts everything every
/// frame (XiaolaiDict's spike, kept).
@MainActor
@Observable
public final class HistoryDrawerPresentation {
    public private(set) var geometry: HistoryDrawerGeometry?
    public var revealed = false

    public init() {}

    /// Placed by the controller when the drawer opens: the window's rect is worked out before anything is shown.
    func place(_ geometry: HistoryDrawerGeometry) {
        self.geometry = geometry
    }
}

/// **The drawer's window** (plan-history-and-learning §1, §4; ported from XiaolaiDict's `HistoryDrawerController`): a
/// borderless, transparent window at the display's right edge, full height, with the glass content sliding inside it.
/// Closed by a click anywhere outside it, by Escape while it is open, and by a change of the display's geometry.
@MainActor
public final class HistoryDrawerController {
    public let model: HistoryModel
    /// The view's state: the docked rect, and whether the content has slid in.
    public let presentation = HistoryDrawerPresentation()
    public private(set) var panel: NSPanel?
    /// Called on every change of what the reader sees: the menu-bar item highlights while the drawer is open.
    public var onVisibilityChange: (@MainActor (Bool) -> Void)?
    /// The owned menu-bar button's frame on screen: the drawer opens on that display. Nil falls back to the pointer's.
    public var statusItemFrame: (@MainActor () -> CGRect?)?
    private let study: StudyModel?
    private let onReview: (() -> Void)?
    private var monitors: [Any] = []
    private var escape: Any?
    private var screens: NSObjectProtocol?
    private var hiding: Task<Void, Never>?

    public init(model: HistoryModel, study: StudyModel? = nil, onReview: (() -> Void)? = nil) {
        self.model = model
        self.study = study
        self.onReview = onReview
    }

    public var isOpen: Bool { panel?.isVisible == true && presentation.revealed }

    /// **The reader asked for the history** (a left click on the menu-bar icon): show it, never toggle it — a repeated
    /// click keeps it open (XiaolaiDict's decision, kept).
    public func show() {
        // Shown, not toggled: a repeated click on the icon keeps the drawer open, so the second is a no-op.
        guard !presentation.revealed else { return }
        hiding?.cancel()
        hiding = nil
        let screen = Self.screen(for: statusItemFrame?()) ?? NSScreen.main
        guard let screen else { return }
        let geometry = HistoryDrawerGeometry.make(
            width: Tokens.Window.historyDrawerWidth, visible: screen.visibleFrame, screen: screen.frame,
            cornerRadius: Tokens.Window.drawerCornerRadius, shadowMargin: Tokens.Window.drawerShadowMargin)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(geometry.window, display: true)
        presentation.place(geometry)
        panel.orderFrontRegardless()
        withAnimation(Motion.drawerOpen) { presentation.revealed = true }
        onVisibilityChange?(true)
        observeClicks()
        observeEscape()
        observeScreens()
        Task { @MainActor [weak self] in await self?.model.refresh() }
    }

    public func hide() {
        guard panel != nil, presentation.revealed || isVisiblePanel else { return }
        withAnimation(Motion.drawerClose) { presentation.revealed = false }
        onVisibilityChange?(false)
        stopObserving()
        hiding?.cancel()
        hiding = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Tokens.Motion.drawerSettleMilliseconds)))
            guard !Task.isCancelled, let self, !self.presentation.revealed else { return }
            self.panel?.orderOut(nil)
        }
    }

    private var isVisiblePanel: Bool { panel?.isVisible == true }

    private func stopObserving() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        if let escape {
            NSEvent.removeMonitor(escape)
        }
        escape = nil
        if let screens {
            NotificationCenter.default.removeObserver(screens)
        }
        screens = nil
    }

    private func makePanel() -> NSPanel {
        let panel = HistoryDrawerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HistoryView(model: model, study: study, onReview: onReview,
                                                               presentation: presentation))
        panel.setAccessibilityIdentifier("history.drawer")
        return panel
    }

    /// A click outside closes it; a click inside is the reader's, whether it opens the language menu or selects text.
    /// The drawer's own rect is the test, not the window's: the window is grown for the shadow.
    private func observeClicks() {
        for mask in [NSEvent.EventTypeMask.leftMouseDown, .rightMouseDown] {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }) {
                monitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                let closes = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let geometry = self.presentation.geometry, self.isOpen,
                          !geometry.content.contains(NSEvent.mouseLocation) else { return false }
                    self.hide()
                    return true
                }
                return closes ? nil : event
            }) {
                monitors.append(local)
            }
        }
    }

    /// Escape closes it, and is claimed only while the drawer is open: the lookup panel's own claim is not disturbed.
    private func observeEscape() {
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let claimed = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.keyCode == 53, self.isOpen else { return false }
                self.hide()
                return true
            }
            return claimed ? nil : event
        }
    }

    /// The display's geometry changed: the rect was placed for the old one, so the drawer closes rather than float.
    private func observeScreens() {
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    /// The display the item's click happened on; the pointer's, for a caller with no item; else the main screen.
    static func screen(for item: CGRect?) -> NSScreen? {
        if let item, let screen = NSScreen.screens.first(where: { $0.frame.contains(item) }) {
            return screen
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }
}

/// The drawer takes clicks and keys (its language menu, its selectable sentences) without activating XDict.
final class HistoryDrawerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The drawer's one motion: two springs, arriving with a little give and leaving without one, and a cross-fade with no
/// travel under Reduce Motion.
enum Motion {
    static var drawerOpen: Animation { .spring(response: Tokens.Motion.drawerOpenResponse,
                                               dampingFraction: Tokens.Motion.drawerOpenDamping) }
    static var drawerClose: Animation { .spring(response: Tokens.Motion.drawerCloseResponse,
                                                dampingFraction: Tokens.Motion.drawerCloseDamping) }

    /// With Reduce Motion the drawer does not travel: it is already in place, and only its opacity changes.
    static var travels: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func travel(_ distance: CGFloat) -> CGFloat { travels ? distance : 0 }
}

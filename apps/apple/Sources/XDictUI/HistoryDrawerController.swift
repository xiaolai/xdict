import AppKit
import SwiftUI
import XDictTokens

/// **Where the drawer sits** (plan-history-and-learning §1): under the menu-bar item, its right edge at the item's, and
/// its whole frame inside the screen's visible frame. Pure geometry, so a small screen and a large one are tests, not
/// looks.
public enum HistoryDrawerPlacement {
    public static func frame(size: CGSize, anchor: CGRect, visible: CGRect, margin: CGFloat) -> CGRect {
        let x = min(max(visible.minX + margin, anchor.maxX - size.width), visible.maxX - margin - size.width)
        let below = anchor.minY - margin - size.height
        let y = max(visible.minY + margin, min(below, visible.maxY - margin - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// **The drawer's window** (plan-history-and-learning §1, §4): placed at its final rect before it is shown, closed by a
/// click anywhere else (global and local mouse monitors), by Escape while it is open only, and by a change of the screen's
/// geometry — it is pinned to the screen it opened on rather than floating somewhere it was never placed.
@MainActor
public final class HistoryDrawerController {
    public let model: HistoryModel
    public private(set) var panel: NSPanel?
    private var monitors: [Any] = []
    private var escape: Any?
    private var screens: NSObjectProtocol?

    /// `study` writes a card's note; `onReview` opens the review window from the drawer's header.
    public init(model: HistoryModel, study: StudyModel? = nil, onReview: (() -> Void)? = nil) {
        self.model = model
        self.study = study
        self.onReview = onReview
    }

    private let study: StudyModel?
    private let onReview: (() -> Void)?

    public var isOpen: Bool { panel?.isVisible == true }

    public func toggle(near anchor: CGRect, on screen: NSScreen?) {
        if isOpen {
            close()
        } else {
            show(near: anchor, on: screen)
        }
    }

    public func show(near anchor: CGRect, on screen: NSScreen?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = CGSize(width: Tokens.Window.historyDrawerWidth, height: Tokens.Window.historyDrawerHeight)
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(origin: .zero, size: size)
        panel.setFrame(HistoryDrawerPlacement.frame(size: size, anchor: anchor, visible: visible,
                                                    margin: Tokens.Space.s), display: true)
        panel.orderFrontRegardless()
        observeClicks()
        observeEscape()
        observeScreens()
        Task { @MainActor [weak self] in await self?.model.refresh() }
    }

    public func close() {
        panel?.orderOut(nil)
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
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HistoryView(model: model, study: study, onReview: onReview))
        panel.setAccessibilityIdentifier("history.drawer")
        return panel
    }

    /// A click outside closes it; a click inside is the reader's, whether it opens the language menu or selects text.
    private func observeClicks() {
        for mask in [NSEvent.EventTypeMask.leftMouseDown, .rightMouseDown] {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }) {
                monitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                // The decision is made on the main actor; the event itself never crosses that boundary.
                let closes = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let panel = self.panel, panel.isVisible,
                          !panel.frame.contains(NSEvent.mouseLocation) else { return false }
                    self.close()
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
                self.close()
                return true
            }
            return claimed ? nil : event
        }
    }

    /// The screen's geometry changed: the frame was placed for the old one, so the drawer closes rather than float.
    private func observeScreens() {
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
}

/// The drawer takes clicks and keys (its language menu, its selectable sentences) without activating XDict.
final class HistoryDrawerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

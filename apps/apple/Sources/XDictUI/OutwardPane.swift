import AppKit
import SwiftUI
import XDictTokens

/// Adds the right pane outside the reader's existing window, before presenting the native inspector (ADR-0030).
/// Frame changes and SwiftUI callbacks happen on the next main-loop turn, never during a native layout/update.
struct OutwardPane: NSViewRepresentable {
    let shown: Bool
    let width: CGFloat
    @Binding var presentation: MeaningPlacement

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.shown = shown
        probe.paneWidth = width
        probe.changed = { presentation = $0 }
        probe.schedule()
    }

    /// The frame before and after opening. Near the screen's right edge, move only as far left as necessary.
    struct Expansion {
        let original: NSRect
        let expanded: NSRect
        var width: CGFloat

        init?(frame: NSRect, visible: NSRect, width: CGFloat) {
            guard width > 0, frame.width + width <= visible.width else { return nil }
            original = frame
            self.width = width
            var next = frame
            next.size.width += width
            next.origin.x = max(visible.minX, min(frame.minX, visible.maxX - next.width))
            expanded = next
        }

        /// Subtract only the pane, retaining a reader's later resize or move. Undo our screen-edge shift if unmoved.
        func closing(_ frame: NSRect) -> NSRect {
            var next = frame
            next.size.width = max(ToolbarLayout.minimumWindow.width, frame.width - width)
            if frame.minX == expanded.minX { next.origin.x = original.minX }
            return next
        }
    }

    final class Probe: NSView {
        var shown = false
        var paneWidth = Tokens.Window.meaningPaneIdeal
        var changed: ((MeaningPlacement) -> Void)?
        private var presented: MeaningPlacement = .hidden
        private var expansion: Expansion?
        private var pending = false
        private var fullScreenFrame = false
        private var reconsiderSheet = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            fullScreenFrame = window?.styleMask.contains(.fullScreen) ?? false
            if let window {
                for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                             NSWindow.didExitFullScreenNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)),
                                                           name: name, object: window)
                }
            }
            schedule()
        }

        @objc private func windowChanged(_ notification: Notification) {
            switch notification.name {
            case NSWindow.didEnterFullScreenNotification:
                fullScreenFrame = true
            case NSWindow.didExitFullScreenNotification:
                fullScreenFrame = false
                reconsiderSheet = true
            default: break
            }
            schedule()
        }

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
            guard let window else { return }
            let fullScreen = fullScreenFrame || window.styleMask.contains(.fullScreen)
            // First dismiss, then contract on the following turn: never squeeze a still-open inspector into the
            // original compact window. In full screen, defer the contraction until AppKit restores its normal frame.
            if !shown {
                if presented != .hidden {
                    presented = .hidden
                    changed?(.hidden)
                    schedule()
                } else if let expansion, !fullScreen {
                    self.expansion = nil
                    window.setFrame(expansion.closing(window.frame), display: true)
                }
                return
            }
            if presented == .hidden, expansion != nil, !fullScreen {
                // A close immediately followed by another open can arrive before the deferred contraction.
                presented = .inspector
                changed?(.inspector)
                return
            }
            if presented == .inspector {
                guard let reserved = expansion else { return }
                if fullScreen {
                    presented = .sheet
                    changed?(.sheet)
                } else if window.frame.width < ToolbarLayout.minimumWindow.width + reserved.width {
                    // Only a deliberate narrowing discards the reservation: its requested frame becomes the base.
                    expansion = nil
                    presented = .sheet
                    changed?(.sheet)
                } else if paneWidth != reserved.width, let screen = window.screen {
                    // Dragging the divider changes the reservation and outer frame together, preserving reading
                    // width. A reservation is never changed without applying its matching frame change.
                    if let next = Expansion(frame: reserved.closing(window.frame), visible: screen.visibleFrame,
                                            width: paneWidth) {
                        expansion = next
                        window.setFrame(next.expanded, display: true)
                    } else {
                        presented = .sheet
                        changed?(.sheet)
                        schedule()
                    }
                }
                return
            }
            if presented == .sheet {
                guard !fullScreen, expansion != nil || reconsiderSheet else { return }
                if let expansion {
                    self.expansion = nil
                    window.setFrame(expansion.closing(window.frame), display: true)
                }
            }
            reconsiderSheet = false
            if !fullScreen, let screen = window.screen,
               let next = Expansion(frame: window.frame, visible: screen.visibleFrame, width: paneWidth) {
                expansion = next
                window.setFrame(next.expanded, display: true)
                presented = .inspector
            } else {
                // A full-screen or screen-filling window cannot grow without taking room from the entry.
                presented = .sheet
            }
            changed?(presented)
        }
    }
}

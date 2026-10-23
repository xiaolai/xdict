import AppKit
import SwiftUI

/// **A window's least frame, held by Auto Layout on its content view** (parity P1; native capture
/// `main.meaningCompactReopened`, 2026-10-23): a 400 pt window before its first search was 584 pt once the search
/// brought the results list.
///
/// Measured (`MeaningPaneFitTests`, diag 2026-10-23): any least the window reports — a SwiftUI `.frame(minWidth:)`
/// around the split view, or AppKit's `minSize` or `contentMinSize` — is taken by the split view as its entry
/// column's least while the list is collapsed, so revealing the list needs the sidebar beside a 400 pt entry and widens
/// the window by the sidebar, at 400 pt and at 500 pt alike. A `≥` constraint on the content view holds the window
/// at its least for every resize just the same, and the split view's columns still share whatever width the window
/// has.
///
/// The frame (title bar and toolbar included) becomes the content size through the window's own
/// `contentRect(forFrameRect:)`, recomputed when the window's style changes (full screen, a full-size content view).
/// The constraints are made after the probe joins its window, on the next turn, never in a SwiftUI update; nothing
/// here sets SwiftUI state or the window's frame.
public struct WindowMinimum: NSViewRepresentable {
    let frame: NSSize

    public init(_ frame: (width: CGFloat, height: CGFloat)) {
        self.frame = NSSize(width: frame.width, height: frame.height)
    }

    public func makeNSView(context: Context) -> Probe { Probe(frame: frame) }

    public func updateNSView(_ probe: Probe, context: Context) {
        probe.frameMinimum = frame
    }

    /// Joins its window and holds the window's least on its content view.
    public final class Probe: NSView {
        var frameMinimum: NSSize {
            didSet { if frameMinimum != oldValue { holdLater() } }
        }
        private var held: [NSLayoutConstraint] = []
        private var styleObservation: NSKeyValueObservation?

        init(frame minimum: NSSize) {
            frameMinimum = minimum
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            styleObservation = window?.observe(\.styleMask) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.holdLater() }
            }
            holdLater()
        }

        /// On the next turn of the main loop: out of the layout or update that moved the probe.
        private func holdLater() {
            DispatchQueue.main.async { [weak self] in self?.hold() }
        }

        /// The content view at least the frame minimum's content size; the previous constraints, if any, replaced.
        private func hold() {
            NSLayoutConstraint.deactivate(held)
            held = []
            guard let window, let content = window.contentView else { return }
            let least = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameMinimum)).size
            held = [
                content.widthAnchor.constraint(greaterThanOrEqualToConstant: least.width),
                content.heightAnchor.constraint(greaterThanOrEqualToConstant: least.height),
            ]
            NSLayoutConstraint.activate(held)
        }
    }
}

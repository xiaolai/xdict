import AppKit
import SwiftUI

/// **A Settings search result, scrolled to** (UI30): the detail's scroll view, which hands `route` to the rows marked
/// with `settingsAnchor(_:)`; the row a reveal names scrolls itself into view once it is drawn.
///
/// Not `ScrollViewReader.scrollTo`: a grouped `Form`'s rows are AppKit's, so an `id` inside one is not an id the
/// detail's `ScrollView` can find, and the request went unanswered (native capture `settings.searchPrompt`).
public struct SettingsRevealScroll<Content: View>: View {
    private let route: SettingsRoute
    private let content: Content

    public init(route: SettingsRoute, @ViewBuilder content: () -> Content) {
        self.route = route
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .top)
                .environment(route)
        }
    }
}

extension View {
    /// Marks the row a Settings search result reveals (`SettingsSearch.Anchor`): when `SettingsRoute.revealed` names
    /// it, the row is brought to the top of the detail as soon as it is in the window, and the request is completed.
    public func settingsAnchor(_ anchor: SettingsSearch.Anchor) -> some View {
        modifier(SettingsAnchor(anchor: anchor))
    }
}

private struct SettingsAnchor: ViewModifier {
    let anchor: SettingsSearch.Anchor
    @Environment(SettingsRoute.self) private var route: SettingsRoute?

    func body(content: Content) -> some View {
        // The serial is read here, so every reveal reaches the marker, even of the row revealed last time.
        content.background { SettingsAnchorMarker(anchor: anchor, route: route, serial: route?.revealSerial ?? 0) }
    }
}

private struct SettingsAnchorMarker: NSViewRepresentable {
    let anchor: SettingsSearch.Anchor
    let route: SettingsRoute?
    let serial: Int

    func makeNSView(context: Context) -> SettingsAnchorView { SettingsAnchorView() }
    func updateNSView(_ view: SettingsAnchorView, context: Context) { view.ask(route, anchor) }
}

/// A row's AppKit footprint: where the row is drawn, and so where the detail's scroll view must go to show it.
@MainActor
final class SettingsAnchorView: NSView {
    private weak var route: SettingsRoute?
    private var anchor: SettingsSearch.Anchor?
    /// One hop is in flight; a second ask in the same turn adds nothing.
    private var scheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A reveal or a fresh row: try once the row is in a window.
    func ask(_ route: SettingsRoute?, _ anchor: SettingsSearch.Anchor) {
        self.route = route
        self.anchor = anchor
        schedule()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedule()
    }

    /// After the turn that asked: by then SwiftUI has handed this turn's changes (a pane drawn, a disclosure opened)
    /// to AppKit, and `reveal()` lays them out before measuring.
    private func schedule() {
        guard !scheduled, window != nil, let route, route.revealed == anchor else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.reveal()
        }
    }

    private func reveal() {
        guard let route, let anchor, route.revealed == anchor, let window else { return }
        let serial = route.revealSerial
        window.contentView?.layoutSubtreeIfNeeded()
        if let scroll = scrollingAncestor(), let document = scroll.documentView {
            let clip = scroll.contentView
            let row = convert(bounds, to: document)
            var shown = clip.bounds
            shown.origin.y = (document.isFlipped ? row.minY : row.maxY - shown.height) - scroll.contentInsets.top
            clip.scroll(to: clip.constrainBoundsRect(shown).origin)
            scroll.reflectScrolledClipView(clip)
        }
        route.didReveal(serial: serial)
    }

    /// The nearest enclosing scroll view with room to scroll: the detail's, past the Form's own fixed-size one.
    private func scrollingAncestor() -> NSScrollView? {
        var view = superview
        while let current = view {
            if let scroll = current as? NSScrollView, let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height {
                return scroll
            }
            view = current.superview
        }
        return nil
    }
}

import AppKit

/// **Every toolbar item has a name** (verifier, 2026-10-19: the Back/Forward pair, the text-size pair and the search
/// field had empty labels, so VoiceOver and the overflow menu had nothing to say for them). SwiftUI names a hosted
/// view's item only once it first goes to the overflow, and a `ControlGroup`'s segmented control not at all, so the
/// window's watcher (`ToolbarFieldWidth`) names them: the item holding the search field "Search", and each pair by the
/// help its first segment carries (`SearchToolbar`), in the reader's language.
@MainActor
enum ToolbarLabels {
    /// A pair's name, by its first segment's help.
    static var pairs: [String: String] {
        [String(localized: "Show the previous result"): String(localized: "Back/Forward"),
         String(localized: "Decrease font size"): String(localized: "Text Size")]
    }

    static func apply(_ field: NSView, in toolbar: NSToolbar) {
        let pairs = Self.pairs
        for item in toolbar.items {
            guard let view = item.view else { continue }
            if field.isDescendant(of: view) {
                name(item, String(localized: "Search"))
            } else if let control = segmented(in: view), control.segmentCount > 0,
                      let name = control.toolTip(forSegment: 0).flatMap({ pairs[$0] }) {
                self.name(item, name)
                if control.accessibilityLabel() != name { control.setAccessibilityLabel(name) }
            }
        }
    }

    private static func name(_ item: NSToolbarItem, _ name: String) {
        if item.label != name { item.label = name }
        if item.paletteLabel != name { item.paletteLabel = name }
    }

    private static func segmented(in view: NSView) -> NSSegmentedControl? {
        (view as? NSSegmentedControl) ?? view.subviews.lazy.compactMap(segmented(in:)).first
    }
}

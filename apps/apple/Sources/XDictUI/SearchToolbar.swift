import SwiftUI

/// **The main window's toolbar** (P3): Back/Forward | title | space | Smaller/Bigger Text | speaker (P48) | search. At
/// the 400 pt minimum the two pairs go to the overflow before the search field does (P8). Its own type, so a test lays
/// out these very items in a window (`ToolbarFitTests`).
struct SearchToolbar<Field: View>: ToolbarContent {
    let canGoBack: Bool
    let canGoForward: Bool
    let canPronounce: Bool
    let back: @MainActor () -> Void
    let forward: @MainActor () -> Void
    let smaller: @MainActor () -> Void
    let bigger: @MainActor () -> Void
    let pronounce: @MainActor () -> Void
    let field: Field

    var body: some ToolbarContent {  // placement: P3
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button(action: back) { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!canGoBack)
                    .help(Text("Show the previous result"))
                Button(action: forward) { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!canGoForward)
                    .help(Text("Show the next result"))
            }
            .controlGroupStyle(.navigation)
        }
        .visibilityPriority(.low)
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button(action: smaller) { Label("Smaller Text", systemImage: "textformat.size.smaller") }
                    .help(Text("Decrease font size"))
                Button(action: bigger) { Label("Bigger Text", systemImage: "textformat.size.larger") }
                    .help(Text("Increase font size"))
            }
            // One two-segment control, as Apple's (P3), not two round buttons (owner, 2026-10-18): the same style
            // that joins Back and Forward.
            .controlGroupStyle(.navigation)
        }
        .visibilityPriority(.low)
        ToolbarItem(placement: .primaryAction) {
            Button(action: pronounce) { Label("Pronounce", systemImage: "speaker.wave.2") }  // placement: P48
                .disabled(!canPronounce)
                .help(Text("Read the selection aloud, or the entry’s word when nothing is selected"))
                .accessibilityIdentifier("toolbar.pronounce")
        }
        .visibilityPriority(.low)
        ToolbarItem(placement: .primaryAction) {
            field
                // Bounds only: the width within them follows the window (P5: 327 pt at 859 pt), set on the toolbar's
                // item by `ToolbarFieldWidth`. A width here is measured once by the toolbar and kept, so a window-
                // following one overflowed its slot when the window was stretched (owner, 2026-10-19).
                .frame(minWidth: ToolbarLayout.searchWidth.min, maxWidth: ToolbarLayout.searchWidth.max)
        }
        .visibilityPriority(.high)
    }
}

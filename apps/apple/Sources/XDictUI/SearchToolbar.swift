import SwiftUI

/// **The main window's toolbar** (P3): Back/Forward | speaker (P48) | title | space | search | Smaller/Bigger Text. The
/// owner put the search before the text-size pair (2026-10-24: "move search before font-size changers"), which also
/// keeps the pair between the field and the answer pane's toggle, so the two show as separate buttons. At the 400 pt
/// minimum the toolbar's items go to the overflow before the search field does (P8). Its own type, so a test lays out
/// these very items in a window (`ToolbarFitTests`).
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
            } label: {
                // The item's name, for VoiceOver and the overflow menu (verifier, 2026-10-19: it had none).
                Label("Back/Forward", systemImage: "chevron.backward")
            }
            .controlGroupStyle(.navigation)
        }
        .visibilityPriority(.low)
        // The speaker in the leading cluster, after Back/Forward (owner, 2026-10-19): the toolbar gives up its trailing
        // items first, and beside the text-size pair the speaker was the one a jump to a narrow window hid.
        ToolbarItem(placement: .navigation) {
            Button(action: pronounce) { Label("Pronounce", systemImage: "speaker.wave.2") }  // placement: P48
                .disabled(!canPronounce)
                .help(Text("Read the selection aloud, or the entry’s word when nothing is selected"))
                .accessibilityIdentifier("toolbar.pronounce")
        }
        .visibilityPriority(.high)
        ToolbarItem(placement: .primaryAction) {
            field
        }
        .visibilityPriority(.high)
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button(action: smaller) { Label("Smaller Text", systemImage: "textformat.size.smaller") }
                    .help(Text("Decrease font size"))
                Button(action: bigger) { Label("Bigger Text", systemImage: "textformat.size.larger") }
                    .help(Text("Increase font size"))
            } label: {
                Label("Text Size", systemImage: "textformat.size")
            }
            // One two-segment control, as Apple's (P3), not two round buttons (owner, 2026-10-18): the same style
            // that joins Back and Forward.
            .controlGroupStyle(.navigation)
        }
        .visibilityPriority(.low)
    }
}

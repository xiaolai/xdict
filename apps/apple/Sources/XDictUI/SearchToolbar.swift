import SwiftUI
import XDictContract
import XDictSearch

/// **The main window's toolbar** (P3): Back/Forward | speaker (P48) | title | space | search. **The search is SwiftUI's
/// `.searchable`** (owner, 2026-10-24), a toolbar item the system places at the trailing end. **The text-size pair left
/// the toolbar** (owner, 2026-10-24): View ▸ Bigger/Smaller Text still carries it, with keys. So did the answer pane's
/// toggle, which now lives in the pane's own window and on ⌘I.
struct SearchToolbar: ToolbarContent {
    let canGoBack: Bool
    let canGoForward: Bool
    let canPronounce: Bool
    let back: @MainActor () -> Void
    let forward: @MainActor () -> Void
    let pronounce: @MainActor () -> Void
    /// **Explore, beside the speaker**: the word on screen, its rhymes, family, roots and forms (WI-3). A test that
    /// measures the toolbar's layout leaves it out.
    var explore: ExploreModel?
    var exploreWord: @MainActor () -> String = { "" }
    var exploreDicts: @MainActor () -> [DictId] = { [] }
    var exploreOpen: @MainActor (ExploreRow) -> Void = { _ in }
    /// The row's other route: the entry that said it, opened by its own key (audit, 2026-10-28).
    var exploreOpenEntry: @MainActor (ExploreRow) -> Void = { _ in }
    /// Run before the panel's first ask, so a restarted service gets its pack back.
    var explorePrepare: @MainActor () async -> Void = {}

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
        if let explore {
            ToolbarItem(placement: .navigation) {
                ExploreButton(model: explore, word: exploreWord, dicts: exploreDicts, open: exploreOpen,
                              openEntry: exploreOpenEntry, prepare: explorePrepare)
            }
            .visibilityPriority(.low)
        }
    }
}

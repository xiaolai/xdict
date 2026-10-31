import SwiftUI
import XDictContract
import XDictSearch
import XDictTokens

/// **Explore, from the word on screen** (plan-word-exploration WI-3): the toolbar button and the panel it opens — one
/// tab at a time, a row per word the reader's own dictionaries hold, and each row opens that entry.
struct ExploreButton: View {
    let model: ExploreModel
    let word: @MainActor () -> String
    let dicts: @MainActor () -> [DictId]
    let open: @MainActor (ExploreRow) -> Void
    let openEntry: @MainActor (ExploreRow) -> Void
    let prepare: @MainActor () async -> Void
    @State private var showing = false

    var body: some View {
        Button {  // placement: P3
            // **The panel asks only once the pack is where the service can see it**: a service that restarted holds
            // none, and a mode that needs one would answer "not installed" over a profile that says otherwise.
            Task { @MainActor in
                await prepare()
                model.show(model.tab, word: word(), dicts: dicts())
                showing = true
            }
        } label: {
            Label("Explore", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .disabled(word().isEmpty)
        .help(Text("Rhymes, word families, roots and forms of this word"))
        .accessibilityIdentifier("toolbar.explore")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ExplorePopover(model: model, word: word, dicts: dicts, open: open, openEntry: openEntry)
        }
    }
}

/// The panel: the word, the tabs, and what the chosen tab found — or why it could not look.
struct ExplorePopover: View {
    let model: ExploreModel
    let word: @MainActor () -> String
    let dicts: @MainActor () -> [DictId]
    let open: @MainActor (ExploreRow) -> Void
    let openEntry: @MainActor (ExploreRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            // **The heading names the word the rows are about** (audit, 2026-10-28): the live search word changes as the
            // reader keeps typing, and a page for the last one shown would then be labelled with a word it never asked
            // about — the reader could open a row believing it belonged to the new word.
            Text(model.word.isEmpty ? word() : model.word).font(Tokens.TextRole.headline.font).lineLimit(1)
            // **The tabs wrap** (owner, 2026-10-29): a segmented control could not fit seven segments in the panel and
            // was clipped at its edge, growing when a tab was clicked. See `ExploreTabs`.
            ExploreTabs(chosen: model.tab) { tab in
                model.show(tab, word: word(), dicts: dicts())
            }
            rows
        }
        .padding(Tokens.Space.l)
        .frame(width: Tokens.Window.explorePopoverWidth, alignment: .leading)
        .accessibilityIdentifier("explore.panel")
    }

    @ViewBuilder private var rows: some View {
        if let sentence = ExploreSentences.state(model.page, tab: model.tab,
                                                  word: model.word.isEmpty ? word() : model.word) {
            Text(sentence)
                .font(Tokens.TextRole.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("explore.state")
        }
        // **A row is a list row, not a control's box** (owner, 2026-10-31): the `List` that held the answer drew every
        // row with its own white fill, a row separator's hairline and square corners, and stretched each row over the
        // list's height so its text sat at the top of a tall box. The app's list rows are plain text on the surface —
        // the reading face for the word, the caption role for its reason — in a list row's own line, with a highlight
        // on hover and on the keyboard's selection. A `ScrollView` and a `LazyVStack` of buttons draw that; a `List`
        // has no way to be asked for it here.
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.page.rows, id: \.self) { row in
                    ExploreRowView(row: row, open: open, openEntry: openEntry)
                }
            }
        }
        // **The list is given a height, not only a cap** (owner, 2026-10-31: every tab showed exactly one row): the
        // popover latches its size while the tab is still loading, and neither a `List` nor a `ScrollView` takes a
        // height of its own. A `maxHeight` proposes nothing, so the list kept the leftover space — one row — when the
        // answer's rows arrived, and every tab answered with many drew one. The token is the eight rows drawn from
        // loading on.
        .frame(height: Tokens.Window.exploreListHeight)
        .accessibilityIdentifier("explore.rows")
        // **The next page, when there is one** (audit, 2026-10-28): it was discarded, so a long answer stopped at the
        // first hundred rows with nothing saying more existed.
        if model.page.next != nil, !model.page.loading {
            Button { model.more(dicts: dicts()) } label: { Text(ExploreSentences.more) }  // placement: explore-row
                .buttonStyle(.plain)
                .font(Tokens.TextRole.callout.font)
                .accessibilityIdentifier("explore.more")
        }
    }
}

/// **One word of an Explore answer** (owner, 2026-10-31): a list row of the app's own — the reading face for the word,
/// the caption role for its reason, one row of the sidebar's height with both lines centred in it — and none of a
/// control's chrome. The whole row is the button, so the pointer highlights the line it will open.
private struct ExploreRowView: View {
    let row: ExploreRow
    let open: @MainActor (ExploreRow) -> Void
    let openEntry: @MainActor (ExploreRow) -> Void
    /// The pointer is on this row: its hover highlight shows.
    @State private var hovering = false
    /// The row holds the keyboard's selection: it shows the same highlight, and its word the accent, as a chosen row
    /// of the app's lists does.
    @FocusState private var chosen: Bool

    var body: some View {
        Button { open(row) } label: {  // placement: explore-row
            HStack(spacing: Tokens.Space.s) {
                Text(row.word)
                    .font(ReadingText.body.font)
                    .foregroundStyle(chosen ? Tokens.Colour.accent.color : Tokens.Colour.label.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(ExploreSentences.reason(row.reason))
                    .font(Tokens.TextRole.caption.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Tokens.Space.s)
            .frame(maxWidth: .infinity, minHeight: Tokens.Row.sidebar, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if hovering || chosen {
                    // The sidebar's own selection corner: a list row highlights with a rounded band, never a box.
                    RoundedRectangle(cornerRadius: Tokens.Radius.sidebarSelection, style: .continuous)
                        .fill(.quaternary)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($chosen)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("explore.row")
        // **The other route** (audit, 2026-10-28): the click looks the row's word up; this opens the entry that said
        // the relation, which is what a reader wants when they are checking the claim rather than the word.
        .contextMenu {
            Button { openEntry(row) } label: { Text(ExploreSentences.openEntry) }  // placement: explore-row
        }
    }
}

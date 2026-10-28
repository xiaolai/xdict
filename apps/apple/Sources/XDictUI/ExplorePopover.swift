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
            Picker("Explore", selection: Binding(get: { model.tab },
                                                 set: { model.show($0, word: word(), dicts: dicts()) })) {
                ForEach(ExploreModel.Tab.allCases) { tab in
                    Text(ExploreSentences.tab(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("explore.tabs")
            rows
        }
        .padding(Tokens.Space.l)
        .frame(width: Tokens.Window.explorePopoverWidth, alignment: .leading)
        .accessibilityIdentifier("explore.panel")
    }

    @ViewBuilder private var rows: some View {
        if let sentence = ExploreSentences.state(model.page, tab: model.tab, word: word()) {
            Text(sentence)
                .font(Tokens.TextRole.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("explore.state")
        }
        List(model.page.rows, id: \.self) { row in
            Button { open(row) } label: {  // placement: explore-row
                HStack(spacing: Tokens.Space.s) {
                    Text(row.word)
                    Spacer(minLength: 0)
                    Text(ExploreSentences.reason(row.reason))
                        .font(Tokens.TextRole.caption.font)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // **The other route** (audit, 2026-10-28): the click looks the row's word up; this opens the entry that
            // said the relation, which is what a reader wants when they are checking the claim rather than the word.
            .contextMenu {
                Button { openEntry(row) } label: { Text(ExploreSentences.openEntry) }  // placement: explore-row
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: Tokens.Window.exploreListHeight)
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

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
    @State private var showing = false

    var body: some View {
        Button {  // placement: P3
            model.show(model.tab, word: word(), dicts: dicts())
            showing = true
        } label: {
            Label("Explore", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .disabled(word().isEmpty)
        .help(Text("Rhymes, word families, roots and forms of this word"))
        .accessibilityIdentifier("toolbar.explore")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ExplorePopover(model: model, word: word, dicts: dicts, open: open)
        }
    }
}

/// The panel: the word, the tabs, and what the chosen tab found — or why it could not look.
struct ExplorePopover: View {
    let model: ExploreModel
    let word: @MainActor () -> String
    let dicts: @MainActor () -> [DictId]
    let open: @MainActor (ExploreRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Text(word()).font(Tokens.TextRole.headline.font).lineLimit(1)
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
        }
        .listStyle(.plain)
        .frame(maxHeight: Tokens.Window.exploreListHeight)
        .accessibilityIdentifier("explore.rows")
    }
}

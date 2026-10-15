import SwiftUI
import XDictContract
import XDictSearch

/// **The sidebar**: the search field, then what was typed suggests (Q6, Q7) while the reader types, or the results of
/// the lookup made, one section per dictionary in the reader's order, each painted as it answers (Q12), each result
/// with why it matched (Q4), every record under a key (Q10), and for a dictionary with nothing to show, why, and what
/// the reader can do (Q11).
struct SearchSidebar: View {
    @Bindable var state: SearchWindowState
    @FocusState private var resultsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: state.model.text, prompt: String(localized: "Look Up"), focus: state.searchFocus,
                        onChange: { text in
                            state.model.text = text
                            state.highlighted = nil
                            state.model.textDidChange()
                        },
                        onSubmit: { state.submit() }, onMove: { state.move($0) }, onCancel: { state.cancel() })
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            if state.model.showsSuggestions {
                SuggestionList(state: state)
            } else {
                ResultList(state: state)
                    .focused($resultsFocused)
            }
            if case .failed = state.service {
                Divider()
                Text(state.service.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: state.resultsFocus) { resultsFocused = true }
    }
}

/// What the typed text suggests: keys of the dictionaries in scope (public keys only, so no internal key appears, Q7).
/// ↑ and ↓ in the field move through them; Return or a click looks one up.
struct SuggestionList: View {
    let state: SearchWindowState

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(state.model.suggestions, id: \.self) { key in
                        Button { state.model.submit(key) } label: {
                            Text(verbatim: key)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(state.highlighted == key ? Color.accentColor.opacity(0.25) : Color.clear)
                        .accessibilityIdentifier("suggestion")
                        .accessibilityAddTraits(state.highlighted == key ? .isSelected : [])
                        .id(key)
                    }
                } header: {
                    Text("Suggestions")
                }
            }
            .onChange(of: state.highlighted) { _, key in
                if let key { proxy.scrollTo(key) }
            }
        }
        .accessibilityIdentifier("suggestions")
    }
}

/// The lookup's results, one section per dictionary.
struct ResultList: View {
    let state: SearchWindowState

    var body: some View {
        List(selection: Binding(get: { state.model.selection }, set: { state.model.select($0) })) {
            ForEach(state.model.sections) { section in
                Section {
                    rows(section)
                } header: {
                    SectionHeader(section: section)
                }
            }
        }
        .accessibilityIdentifier("results")
    }

    @ViewBuilder private func rows(_ section: ResultSection) -> some View {
        switch section.status {
        case .results(let results):
            let repeated = results.repeatedKeys
            ForEach(results.hits, id: \.entry) { hit in
                ResultRow(hit: hit, dictionary: section.name,
                          record: repeated.contains(hit.entry.key) ? Int(hit.entry.occurrence) + 1 : nil)
                    .tag(ResultID(dictionary: section.id, entry: hit.entry))
            }
            if results.hasMore {
                MoreRow(state: state, section: section, results: results)
            }
            if let failure = results.moreFailed, let sentence = SearchSentences.status(.failed(failure)) {
                Text(sentence).font(.caption).foregroundStyle(.secondary).selectionDisabled()
            }
        default:
            StatusRow(state: state, section: section)
                .selectionDisabled()
        }
    }
}

/// A dictionary's name, its edition and how many results it has: every result's source (R11).
struct SectionHeader: View {
    /// The rows' own trailing inset in the sidebar's List, so the count ends where a row's highlight does.
    static let trailingInset: CGFloat = 8

    let section: ResultSection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: section.name).fontWeight(.semibold).lineLimit(1)
            if let edition = section.edition {
                Text(verbatim: SearchSentences.edition(edition))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .help(Text("Edition"))
            }
            Spacer(minLength: 4)
            if case .results(let results) = section.status {
                Text(SearchSentences.count(loaded: results.hits.count, total: results.total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // A List's section header runs to the sidebar's edge, where its rows stop short: without this the count meets
        // the divider and reads as part of the entry ("1 result purple"; measured 2 pt from the edge, 2026-10-15).
        .padding(.trailing, Self.trailingInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("section")
    }

    private var label: LocalizedStringResource {
        if case .results(let results) = section.status {
            return SearchSentences.section(name: section.name, edition: section.edition, loaded: results.hits.count,
                                           total: results.total)
        }
        return SearchSentences.section(name: section.name, edition: section.edition)
    }
}

/// One result: its headword, which record it is where a key has several, and why it matched.
struct ResultRow: View {
    let hit: Hit
    let dictionary: String
    let record: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(verbatim: hit.headword).lineLimit(1)
                if let record {
                    Text(SearchSentences.record(record)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(SearchSentences.reason(hit.how)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        // One element, read as text (without the trait its role is unknown to VoiceOver): the headword, the record,
        // why it matched and the dictionary it is in (R11).
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(Text(SearchSentences.result(headword: hit.headword, how: hit.how, record: record,
                                                        dictionary: dictionary)))
        .accessibilityIdentifier("result")
    }
}

/// The next page of a dictionary's results (Q10).
struct MoreRow: View {
    let state: SearchWindowState
    let section: ResultSection
    let results: Results

    var body: some View {
        HStack {
            Button(SearchSentences.more(1_000, remaining: results.total - UInt64(results.hits.count))) {
                state.model.loadMore(section.id)
            }
            .disabled(results.loadingMore)
            .accessibilityIdentifier("more")
            if results.loadingMore { ProgressView().controlSize(.small) }
        }
        .selectionDisabled()
    }
}

/// A dictionary with nothing to show: why, and what the reader can do (Q11).
struct StatusRow: View {
    let state: SearchWindowState
    let section: ResultSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if section.status == .searching { ProgressView().controlSize(.small) }
                if let sentence = SearchSentences.status(section.status) {
                    Text(sentence).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let next = section.next {
                if SearchSentences.isButton(next) {
                    Button(SearchSentences.action(next)) { state.perform(next) }
                        .controlSize(.small)
                } else {
                    Text(SearchSentences.action(next)).font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status")
    }
}

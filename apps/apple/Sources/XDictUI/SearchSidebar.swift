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
            // The List's own selection draws the highlight ↑ and ↓ move (UI review M-12); a click looks the key up.
            List(selection: Binding(get: { state.highlighted }, set: { key in
                state.highlighted = key
                if let key { state.model.submit(key) }
            })) {
                Section {
                    ForEach(state.model.suggestions, id: \.self) { key in
                        Text(verbatim: key)
                            .tag(key)
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
        let sections = state.model.sections
        let notFound = sections.filter(Self.isNotFound)
        let gathered = notFound.count > 1
        let notSearched = sections.filter(Self.isUnavailable)
        List(selection: Binding(get: { state.model.selection }, set: { state.model.select($0) })) {
            ForEach(sections.filter { !Self.isUnavailable($0) && !(gathered && Self.isNotFound($0)) }) { section in
                Section {
                    rows(section)
                } header: {
                    SectionHeader(section: section)
                }
            }
            // Several dictionaries without the word: said once, with one hint (UI review M-08).
            if gathered {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SearchSentences.notIn(notFound.map(\.name))).foregroundStyle(.secondary)
                        Text(SearchSentences.action(.checkSpelling)).font(.subheadline).foregroundStyle(.tertiary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .selectionDisabled()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("status")
                }
            }
            // Dictionaries that could not look, after those that did: one row each and one way on (UI review M-05).
            if !notSearched.isEmpty {
                Section {
                    ForEach(notSearched) { section in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: section.name).lineLimit(1)
                            if let sentence = SearchSentences.status(section.status) {
                                ProblemStatus(sentence: sentence, compact: true)
                            }
                        }
                        .selectionDisabled()
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("status")
                    }
                    Button("Show in Library") { state.openLibrary?(notSearched.first?.id) }
                        .controlSize(.small)
                        .selectionDisabled()
                } header: {
                    Text("Not Searched")
                }
            }
        }
        .accessibilityIdentifier("results")
    }

    static func isUnavailable(_ section: ResultSection) -> Bool {
        switch section.status {
        case .unavailable(.indexing): false
        case .unavailable: true
        default: false
        }
    }

    static func isNotFound(_ section: ResultSection) -> Bool {
        if case .noMatch(_, .reader) = section.status { true } else { false }
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
                Text(sentence).font(.subheadline).foregroundStyle(.secondary).selectionDisabled()
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
                // The header's text on the rows' text edge (UI review M-07).
                .padding(.leading, 2)
            if let edition = SearchSentences.inlineEdition(section) {
                Text(verbatim: edition)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if case .results(let results) = section.status {
                Text(SearchSentences.count(loaded: results.hits.count, total: results.total))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        // A List's section header runs to the sidebar's edge, where its rows stop short: without this the count meets
        // the divider and reads as part of the entry ("1 result purple"; measured 2 pt from the edge, 2026-10-15).
        .padding(.trailing, Self.trailingInset)
        .help(section.edition.map { Text(SearchSentences.editionHelp($0)) } ?? Text(verbatim: ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(SearchSentences.header(section)))
        .accessibilityIdentifier("section")
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
                    Text(SearchSentences.record(record)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            // Why it matched, only where that is news: an exact hit is one line (UI review M-06).
            if hit.how != .exact {
                Text(SearchSentences.reason(hit.how)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
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
            if section.status == .searching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if let sentence = SearchSentences.status(section.status) {
                        Text(sentence).foregroundStyle(.secondary)
                    }
                }
            } else if case .failed = section.status, let sentence = SearchSentences.status(section.status) {
                ProblemStatus(sentence: sentence)
            } else if let sentence = SearchSentences.status(section.status) {
                Text(sentence).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let next = section.next {
                if SearchSentences.isButton(next) {
                    Button(SearchSentences.action(next)) { state.perform(next) }
                        .controlSize(.small)
                } else {
                    Text(SearchSentences.action(next)).font(.subheadline).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status")
    }
}

import SwiftUI
import XDictContract
import XDictSearch
import XDictTokens

/// **The Examples section of the right pane** (ADR-0031, plan-reverse-examples WI-5): the bilingual example sentences
/// whose Chinese carries the reader's query, each with the match marked, the English beneath it, and the dictionary and
/// headword it came from. A row opens its entry in the dictionary that printed it. It draws plain text only: no
/// dictionary HTML reaches the pane (ADR-0007 d.14).
struct ExamplesSection: View {
    let state: SearchWindowState

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            header
            if state.examples.failed {
                Text("The examples could not be read.")
                    .font(Tokens.TextRole.callout.font)
                    .foregroundStyle(.secondary)
            } else {
                if !state.examples.hits.isEmpty {
                    rows
                    if morePairs {
                        Text("More pairs were found; these are the first \(ExamplesModel.page).")
                            .font(Tokens.TextRole.caption.font)
                            .foregroundStyle(.tertiary)
                    }
                    if state.examples.capped {
                        // **A stopped scan is not a known more** (audit round 3, 2026-10-25): the page may or may not be
                        // missing pairs, and the footer says which fact it knows.
                        Text("The scan stopped at its limit, so there may be more pairs than these.")
                            .font(Tokens.TextRole.caption.font)
                            .foregroundStyle(.tertiary)
                    }
                }
                preparation
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("examples.section")
    }

    /// **Whether the page shows fewer pairs than the core found** (audit round 1, 2026-10-25): `total` counts every
    /// distinct pair found before the page's 100, so a full scan can find more than it shows; `capped` says the scan
    /// stopped at its own bound, where `total` is a floor. Either way there are more than these rows.
    private var morePairs: Bool {
        state.examples.total > UInt64(state.examples.hits.count)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            Text("Examples")
                .font(Tokens.TextRole.headline.font)
                .accessibilityAddTraits(.isHeader)
            if state.examples.total > 0 {
                Text(state.examples.capped
                     ? "\(state.examples.total)+ found" : "\(state.examples.total) found")
                    .font(Tokens.TextRole.caption.font)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { state.closeExamples() } label: {  // placement: glyph
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide Examples")
            .accessibilityLabel("Hide Examples")
            .accessibilityIdentifier("examples.close")
        }
    }

    /// **The dictionaries still preparing, or the ones that failed, said whether or not other dictionaries produced
    /// hits** (the owner's decision 2; audit round 1, 2026-10-25): one dictionary's results never hide another's build,
    /// and a failure is never silent. "No examples were found." is only every dictionary's answer.
    @ViewBuilder private var preparation: some View {
        // **A build still running and a failed one are two facts** (audit round 2, 2026-10-25): the failure is named
        // even while another dictionary is still building, and "No examples were found." is only every dictionary's
        // answer.
        if !state.examples.preparing.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                HStack(spacing: Tokens.Space.s) {
                    ProgressView().controlSize(.small)  // placement: spinner
                    Text("Building examples…")
                        .font(Tokens.TextRole.callout.font)
                        .foregroundStyle(.secondary)
                }
                let names = state.examples.preparing.compactMap { state.source(for: $0)?.name }
                if !names.isEmpty {
                    Text(verbatim: names.joined(separator: ", "))
                        .font(Tokens.TextRole.caption.font)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        if !state.examples.failedToPrepare.isEmpty {
            Text(state.examples.hits.isEmpty && state.examples.preparing.isEmpty
                 ? LocalizedStringResource("The examples could not be read.")
                 : LocalizedStringResource("Some dictionaries’ examples could not be read."))
                .font(Tokens.TextRole.callout.font)
                .foregroundStyle(.secondary)
        } else if state.examples.preparing.isEmpty, state.examples.hits.isEmpty {
            Text("No examples were found.")
                .font(Tokens.TextRole.callout.font)
                .foregroundStyle(.secondary)
        }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(state.examples.hits.indices, id: \.self) { index in
                if index > state.examples.hits.startIndex { Divider() }
                let hit = state.examples.hits[index]
                VStack(alignment: .leading, spacing: 0) {
                    Button { state.openExample(hit) } label: { pair(hit) }  // placement: inspector-row
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("examples.row")
                    attribution(hit)
                }
            }
        }
    }

    /// The pair itself: what the plain click opens, in the first source the library has.
    private func pair(_ hit: ExampleHit) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            Text(Self.marked(hit))
                .font(ReadingText.body.font)
                .lineSpacing(ReadingText.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: hit.english)
                .font(ReadingText.body.font)
                .lineSpacing(ReadingText.lineSpacing)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Tokens.Space.xs)
        .contentShape(Rectangle())
    }

    /// **A pair's distinct sources the library still has**, in the pair's own order: a removed dictionary is gone, and a
    /// dictionary that printed the same pair under two entries appears once — one menu row and one count per dictionary
    /// (audit round 1, 2026-10-25), since a plain click can only open one of its entries.
    private func availableSources(_ hit: ExampleHit) -> [ExampleSource] {
        var seen: Set<DictId> = []
        return hit.sources.filter { source in
            state.source(for: source.dict) != nil && seen.insert(source.dict).inserted
        }
    }

    /// **A pair's sources**: named; with more than one the library still has, each opens its own dictionary (plan-companion
    /// WI-12). The menu sits outside the row's button, so a click never both opens and picks.
    @ViewBuilder private func attribution(_ hit: ExampleHit) -> some View {
        let available = availableSources(hit)
        if available.count > 1 {
            Menu {  // placement: inspector-row
                ForEach(available, id: \.dict) { candidate in
                    if let source = state.source(for: candidate.dict) {
                        Button(source.name) { state.openExample(hit, in: candidate.dict) }  // placement: inspector-row
                    }
                }
            } label: {
                attributionText(available: available)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // **A long name compresses rather than overflowing the pane** (audit round 3, 2026-10-25); the label already
            // holds one line.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("examples.sources")
        } else {
            attributionText(available: available)
        }
    }

    /// **One available source names both labels** (audit round 1, 2026-10-25): the dictionary and the headword come from
    /// the same source, so a removed first dictionary cannot leave another dictionary's name beside its headword.
    private func attributionText(available: [ExampleSource]) -> some View {
        let source = available.first.flatMap { state.source(for: $0.dict) }
        let headword = available.first?.headword ?? ""
        return HStack(spacing: Tokens.Space.xs) {
            if let source { Text(verbatim: source.name) }
            if !headword.isEmpty { Text(verbatim: "·") }
            if !headword.isEmpty { Text(verbatim: headword) }
            if available.count > 1 { Text("· \(available.count) dictionaries") }
        }
        .font(Tokens.TextRole.caption.font)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .padding(.bottom, Tokens.Space.xs)
    }

    /// **The Chinese with the match marked** (the owner's decision 5): a dotted underline from the token system's line
    /// style and the selected row's weight; both are tokens, no literal.
    static func marked(_ hit: ExampleHit) -> AttributedString {
        let (endOffset, overflow) = hit.start.addingReportingOverflow(hit.len)
        guard !overflow, let start = index(hit.chinese, hit.start), let end = index(hit.chinese, endOffset), start <= end
        else { return AttributedString(hit.chinese) }
        var out = AttributedString(String(hit.chinese[..<start]))
        var match = AttributedString(String(hit.chinese[start..<end]))
        match.underlineStyle = Text.LineStyle(pattern: .dot)
        match.font = ReadingText.emphasized.font
        out.append(match)
        out.append(AttributedString(String(hit.chinese[end...])))
        return out
    }

    /// A UTF-8 byte offset in `text`, as a String index; nil when it splits a character or runs past the end.
    private static func index(_ text: String, _ utf8: UInt64) -> String.Index? {
        guard utf8 <= UInt64(text.utf8.count) else { return nil }
        guard let index = text.utf8.index(text.utf8.startIndex, offsetBy: Int(utf8), limitedBy: text.utf8.endIndex)
        else { return nil }
        return String.Index(index, within: text)
    }
}

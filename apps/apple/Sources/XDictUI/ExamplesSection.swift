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
            } else if state.examples.hits.isEmpty {
                building
            } else {
                rows
                if state.examples.capped {
                    Text("More pairs were found; these are the first \(ExamplesModel.page).")
                        .font(Tokens.TextRole.caption.font)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("examples.section")
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

    /// The dictionaries still preparing, said where the reader would wait for them (the owner's decision 2); one
    /// whose build failed is a failure, not a build still running (audit, 2026-10-24).
    @ViewBuilder private var building: some View {
        if state.examples.preparationFailed {
            Text("The examples could not be read.")
                .font(Tokens.TextRole.callout.font)
                .foregroundStyle(.secondary)
        } else if !state.examples.preparing.isEmpty {
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
        } else {
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
                Button { state.openExample(hit) } label: { row(hit) }  // placement: inspector-row
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("examples.row")
            }
        }
    }

    private func row(_ hit: ExampleHit) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
            Text(marked(hit))
                .font(Tokens.TextRole.sidebarRow.font)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: hit.english)
                .font(Tokens.TextRole.callout.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            attribution(hit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Tokens.Space.xs)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func attribution(_ hit: ExampleHit) -> some View {
        let source = hit.sources.lazy.compactMap { state.source(for: $0.dict) }.first
        let headword = hit.sources.first?.headword ?? ""
        HStack(spacing: Tokens.Space.xs) {
            if let source { Text(verbatim: source.name) }
            if !headword.isEmpty { Text(verbatim: "·") }
            if !headword.isEmpty { Text(verbatim: headword) }
            let dictionaries = Set(hit.sources.map(\.dict)).count
            if dictionaries > 1 { Text("· \(dictionaries) dictionaries") }
        }
        .font(Tokens.TextRole.caption.font)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    /// **The Chinese with the match marked** (the owner's decision 5): a dotted underline from the token system's line
    /// style and the selected row's weight; both are tokens, no literal.
    private func marked(_ hit: ExampleHit) -> AttributedString {
        let (endOffset, overflow) = hit.start.addingReportingOverflow(hit.len)
        guard !overflow, let start = index(hit.chinese, hit.start), let end = index(hit.chinese, endOffset), start <= end
        else { return AttributedString(hit.chinese) }
        var out = AttributedString(String(hit.chinese[..<start]))
        var match = AttributedString(String(hit.chinese[start..<end]))
        match.underlineStyle = Text.LineStyle(pattern: .dot)
        match.font = Tokens.TextRole.sidebarRowSelected.font
        out.append(match)
        out.append(AttributedString(String(hit.chinese[end...])))
        return out
    }

    /// A UTF-8 byte offset in `text`, as a String index; nil when it splits a character or runs past the end.
    private func index(_ text: String, _ utf8: UInt64) -> String.Index? {
        guard utf8 <= UInt64(text.utf8.count) else { return nil }
        guard let index = text.utf8.index(text.utf8.startIndex, offsetBy: Int(utf8), limitedBy: text.utf8.endIndex)
        else { return nil }
        return String.Index(index, within: text)
    }
}

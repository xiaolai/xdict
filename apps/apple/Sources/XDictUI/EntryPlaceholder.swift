import SwiftUI
import XDictSearch

/// **What covers the entry pane while there is no entry to read** (UI review X1, 2026-10-17; Apple parity P12, P14).
/// Every placeholder fills the pane and the entry behind it is closed, so neither the eye nor VoiceOver reaches a
/// previous lookup's entry under "No entries found."; only `.none` keeps the entry. A dictionary that could not search
/// says so in the page's notices, whatever the placeholder (P9: they moved out of the sidebar).
public enum EntryPlaceholder: Equatable, Sendable {
    case noDictionaries
    /// Before the first search: Apple's start page, the prompt and the dictionaries a word is looked up in.
    case start
    case searching
    /// Nothing found: Apple's plain line in the main window.
    case noResults(String)
    /// No result, while `unsearched` dictionaries could not look: not a definitive absence (Codex §5). The main window
    /// says it as `noResults` beside the page's notices; the lookup panel in words of its own.
    case noResultsIncomplete(String, unsearched: Int)
    case none

    /// `pending`: the list has not settled, or has a row about to be shown, so "No entries found." would only flash.
    public static func of(noDictionaries: Bool, query: String?, selection: ResultID?, searching: Bool,
                          unsearched: Int = 0, pending: Bool = false) -> Self {
        if noDictionaries { return .noDictionaries }
        guard let query else { return .start }
        if selection != nil { return .none }
        if searching || pending { return .searching }
        return unsearched > 0 ? .noResultsIncomplete(query, unsearched: unsearched) : .noResults(query)
    }

    /// Whether the entry shown before goes: always, except when there is an entry to show.
    public var clearsEntry: Bool { self != .none }
}

/// A placeholder covers the pane whole, not only its own height (the stale entry showed above a short one).
struct PaneCover: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
    }
}

extension View {
    func coversPane() -> some View { modifier(PaneCover()) }
}

/// **Apple's start page** (P14): centred, in New York, in the secondary label colour — "Type a word to look up in…"
/// at 18 pt, then each dictionary a typed word is looked up in, by name, at 20 pt, on a 32 pt line.
struct StartPage: View {
    let names: [String]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Type a word to look up in…")
                    .font(.system(size: 18, design: .serif))
                    .padding(.bottom, 20)
                ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                    Text(verbatim: name)
                        .font(.system(size: 20, design: .serif))
                        .frame(minHeight: 32)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.horizontal, 16)
        }
        .accessibilityIdentifier("start")
    }
}

/// No result while some dictionaries could not look, in the lookup panel: said as such, not as an absence (Codex §5).
struct NoResultsIncomplete: View {
    let query: String
    let unsearched: Int
    let showDictionaries: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Results in Available Dictionaries", systemImage: "magnifyingglass")
        } description: {
            Text(SearchSentences.noResultsIncomplete(query: query, unsearched: unsearched))
        } actions: {
            Button("Show in Settings", action: showDictionaries)
        }
        .accessibilityIdentifier("no-results-incomplete")
    }
}

/// **Apple's "No entries found."** (P12): one line, system font at 150 % (24 pt), secondary label colour, at the top
/// left of the pane (0.4 em by 0.8 em in from its corner).
struct NoEntriesFound: View {
    var body: some View {
        Text("No entries found.")
            .font(.system(size: 24))
            .foregroundStyle(.secondary)
            .padding(.leading, 19)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("no-entries")
    }
}

import SwiftUI
import XDictSearch

/// **What covers the entry pane while there is no entry to read** (UI review X1, 2026-10-17). Every placeholder fills
/// the pane and the entry behind it is closed, so neither the eye nor VoiceOver reaches a previous lookup's entry under
/// "No Results"; only `.none` keeps the entry.
public enum EntryPlaceholder: Equatable, Sendable {
    case noDictionaries
    case start
    case searching
    case noResults(String)
    /// No result, while `unsearched` dictionaries could not look: not a definitive absence (Codex §5).
    case noResultsIncomplete(String, unsearched: Int)
    case none

    public static func of(noDictionaries: Bool, query: String?, selection: ResultID?, searching: Bool,
                          unsearched: Int = 0) -> Self {
        if noDictionaries { return .noDictionaries }
        guard let query else { return .start }
        if selection != nil { return .none }
        if searching { return .searching }
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

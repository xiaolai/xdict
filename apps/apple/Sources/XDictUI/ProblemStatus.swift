import SwiftUI
import XDictLibrary

/// **One way to say a dictionary cannot be used** (UI review X3, 2026-10-17): a warning symbol in orange and the whole
/// sentence in the text colour, never orange text (unreadable on the selection's blue). `compact` keeps it to one line,
/// the sentence whole in its help, for a list row; the Library's details show it in full.
public struct ProblemStatus: View {
    let sentence: LocalizedStringResource
    var compact = false
    @Environment(\.backgroundProminence) private var prominence

    public var body: some View {
        Label {
            Text(sentence)
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(compact ? 1 : nil)
                .fixedSize(horizontal: false, vertical: !compact)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                .accessibilityHidden(true)
        }
        .font(compact ? .subheadline : .body)
        .help(Text(sentence))
        .accessibilityElement(children: .combine)
        // Said outright: a selectable Text under `.combine` gave the combined element no label at all (E2E lookup
        // checkpoints of 2026-10-18 found the sentence missing while the row's action button, a sibling, was there).
        .accessibilityLabel(Text(sentence))
        .accessibilityIdentifier("problem-status")
    }

    /// The sentence for a dictionary's phase when it cannot be used; nil when it can (or is on its way).
    nonisolated public static func sentence(for phase: EntryPhase?) -> LocalizedStringResource? {
        guard let phase, LibraryRow.isTrouble(phase) else { return nil }
        return LibrarySentences.phase(phase)
    }
}

/// **What a dictionary's row offers for its problem** (UI review L-04): the action that can fix it, not a Retry that
/// cannot — a missing file is located, a file XDict refuses is shown in the Finder, a passing failure is tried again.
public enum LibraryRowAction: Equatable, Sendable {
    case cancel, locate, showInFinder, tryAgain

    public static func `for`(_ phase: EntryPhase?) -> Self? {
        switch phase {
        case .waiting, .importing: .cancel
        case .missing, .outsideItsFolder: .locate
        case .refused: .showInFinder
        case .failed, .cancelled: .tryAgain
        case .cancelling, .opening, .ready, .none: nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .cancel: "Cancel"
        case .locate: "Locate…"
        case .showInFinder: "Show in Finder"
        case .tryAgain: "Try Again"
        }
    }
}

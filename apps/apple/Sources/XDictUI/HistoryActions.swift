import Foundation
import XDictContract
import XDictLibrary
import XDictSearch
import XDictTokens

/// **What a history card offers** (UI43, UI46): one list for the context menu, the keyboard and VoiceOver's actions, so
/// Remove is never only behind a hover. Open Entry and Note appear only where the app wired them.
public enum HistoryCardAction: Equatable, Sendable, CaseIterable {
    case openEntry
    case note
    case remove

    public static func actions(canNote: Bool, canOpen: Bool) -> [HistoryCardAction] {
        allCases.filter {
            switch $0 {
            case .openEntry: canOpen
            case .note: canNote
            case .remove: true
            }
        }
    }

    public var title: LocalizedStringResource {
        switch self {
        case .openEntry: "Open Entry"
        case .note: "Note…"
        case .remove: "Remove from History"
        }
    }
}

/// **What the drawer says instead of cards** (UI50): a failed read is not an empty history, and only it offers a retry.
public enum HistoryNotice: Equatable, Sendable {
    case off
    case empty
    case failed

    /// Nil while loading (a spinner) and when there are cards to show.
    public static func of(_ state: HistoryModel.State, isEmpty: Bool) -> HistoryNotice? {
        switch state {
        case .off: .off
        case .loading: nil
        case .failed: .failed
        case .loaded: isEmpty ? .empty : nil
        }
    }

    public var offersRetry: Bool { self == .failed }

    public var text: LocalizedStringResource {
        switch self {
        case .off: "The reading history is off. Turn it on in Settings ▸ Learning."
        case .empty: "Nothing yet. A word you look up is kept here, with its sentence."
        case .failed: "The reading history could not be read."
        }
    }
}

/// **What the review window says instead of a card** (UI50): a failed read offers Try Again; nothing due does not.
public enum ReviewNotice: Equatable, Sendable {
    case failed
    case nothingDue

    /// Nil while loading and whenever there is a card or a conflict to show.
    public static func of(_ state: StudyModel.State, hasCard: Bool, hasConflicts: Bool) -> ReviewNotice? {
        switch state {
        case .idle, .loading: nil
        case .failed: .failed
        case .ready: hasCard || hasConflicts ? nil : .nothingDue
        }
    }

    public var offersRetry: Bool { self == .failed }
}

/// **Where a recorded entry is now** (UI46, UI48): found by the reading's own edition — the SHA-256 of the whole MDX
/// (ADR-0002) — never by a path, a name or another edition of the lineage. Anything else is said, not guessed.
public enum HistoryEntryLink: Equatable, Sendable {
    /// The edition is in the library and turned on: open exactly this record.
    case entry(ResultID)
    /// The edition is in the library and turned off in Settings ▸ Dictionaries.
    case dictionaryOff(name: String)
    /// No dictionary in the library is this edition: removed, or replaced by a new edition.
    case editionMissing

    public static func resolve(_ ref: EntryRef, in dictionaries: [LibraryEntry]) -> HistoryEntryLink {
        guard !ref.edition.rawValue.isEmpty, !ref.key.isEmpty,
              let dictionary = dictionaries.first(where: { $0.edition == ref.edition && $0.refusal == nil })
        else { return .editionMissing }
        guard dictionary.enabled else { return .dictionaryOff(name: dictionary.displayName) }
        return .entry(ResultID(dictionary: dictionary.id, entry: ref))
    }

    /// The place that opens exactly `result`: its key as the query, its record selected rather than the first match.
    public static func visit(opening result: ResultID) -> Visit {
        Visit(query: result.entry.key, mode: .reader, scope: .all, result: result, typed: result.entry.key,
              isOrigin: true)
    }

    /// **The explicit fallback**: the recorded key looked up in every dictionary, as a word the reader typed. Offered
    /// only on the reader's tap, after the explanation; nil for a key with nothing to look up.
    public static func lookUp(key: String) -> Visit? {
        let query = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return Visit(query: query, mode: .reader, scope: .all, typed: query, isOrigin: true)
    }

    /// The sentence that explains an entry that cannot be opened; nil for one that can.
    public var explanation: LocalizedStringResource? {
        switch self {
        case .entry: nil
        case .dictionaryOff(let name): "“\(name)” is turned off in Settings ▸ Dictionaries."
        case .editionMissing: "The dictionary edition this was read in is no longer in your library."
        }
    }
}

/// **The shell's way to a recorded entry**: the library to resolve against and the main window to open in, wired by the
/// app. A model without it offers no Open Entry.
public struct HistoryEntryLinks {
    public let resolve: @MainActor (EntryRef) -> HistoryEntryLink
    public let open: @MainActor (Visit) -> Void

    public init(resolve: @escaping @MainActor (EntryRef) -> HistoryEntryLink,
                open: @escaping @MainActor (Visit) -> Void) {
        self.resolve = resolve
        self.open = open
    }
}

/// **A history card's frame** (UI45, user-approved 2026-10-23): a neutral hairline. A colour per card meant nothing to
/// the reader and could be read as a category, a status or a source; the soft shadow stays (owner, 2026-10-21).
public enum HistoryCardStyle {
    public static var border: TokenColour { Tokens.Colour.separator }
}

extension EntryRef {
    /// The entry a reading names: its edition, key and occurrence, as recorded.
    public init(reading: LedgerReading) {
        self.init(edition: Edition(rawValue: reading.edition), key: reading.entryKey, occurrence: reading.occurrence)
    }

    /// The entry a review card's target names.
    public init(target: StudyTarget) {
        self.init(edition: Edition(rawValue: target.edition), key: target.entryKey, occurrence: target.occurrence)
    }
}

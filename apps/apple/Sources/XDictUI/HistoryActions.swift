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

/// **A history card's tint** (owner, 2026-10-31; supersedes UI45's neutral hairline): the card's border takes one of the
/// system's own tints, chosen from the card's identity — its word, entry key and edition — through a fixed-seed hash.
/// The identity is stored with the reading, so the same card keeps its colour across redraws, scrolling and launches,
/// and two different cards usually take different tints. Never a fill: the drawer draws the tint at
/// `Tokens.Opacity.cardBorder`, so the card's ink and the drawer's glass stay in charge.
public enum HistoryCardTint {
    /// The group's ten tints, in one list: `index` is always in `0..<tints.count`, and the tests hold that range.
    /// Computed, as the generated tint tokens are: `TokenColour` carries an `NSColor`, which is not `Sendable`.
    public static var tints: [TokenColour] {
        [
            Tokens.Tint.red, Tokens.Tint.orange, Tokens.Tint.yellow, Tokens.Tint.green, Tokens.Tint.blue,
            Tokens.Tint.purple, Tokens.Tint.pink, Tokens.Tint.teal, Tokens.Tint.indigo, Tokens.Tint.brown,
        ]
    }

    /// **The card's own index**: FNV-1a with a 64-bit final mix over the word, the entry key and the edition — a fixed
    /// seed, never `Hasher`, which macOS reseeds per process and would re-roll every card at launch.
    public static func index(for reading: LedgerReading) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for part in [reading.surface, reading.entryKey, reading.edition] {
            for byte in part.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            // 0xFF never occurs in UTF-8, so two different part lists never hash the same bytes.
            hash ^= 0xff
            hash = hash &* 0x0000_0100_0000_01b3
        }
        // FNV-1a's low bits stay weak after a short input, and the modulus reads them: the final mix spreads them.
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        hash = hash &* 0xc4ce_b9fe_1a85_ec53
        hash ^= hash >> 33
        return Int(hash % UInt64(tints.count))
    }

    /// The tint the card's border takes.
    public static func colour(for reading: LedgerReading) -> TokenColour {
        tints[index(for: reading)]
    }
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

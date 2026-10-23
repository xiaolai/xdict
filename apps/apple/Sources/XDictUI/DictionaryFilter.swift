import Foundation
import XDictLibrary

/// **One row's state in Settings ▸ Dictionaries** (UI34): ready, off, under way or in trouble, said in words and a
/// symbol — never colour alone. A ready row draws nothing extra, as Apple's list draws nothing for an ordinary row.
public enum DictionaryRowStatus: CaseIterable, Hashable, Sendable {
    case ready, off, importing, cancelled, missing, damaged, failed

    /// The row's state from its switch and its import phase. A file that is gone outranks the switch: an unchecked
    /// dictionary whose file went is still a dictionary to locate.
    public static func of(enabled: Bool, phase: EntryPhase?) -> DictionaryRowStatus {
        switch phase {
        case .waiting, .importing, .opening, .cancelling: .importing
        case .cancelled: .cancelled
        case .missing, .outsideItsFolder: .missing
        case .refused: .damaged
        case .failed: .failed
        case .ready, nil: enabled ? .ready : .off
        }
    }

    /// The SF Symbol beside the row's name; none for a ready row.
    public var symbol: String? {
        switch self {
        case .ready: nil
        case .off: "minus.circle"
        case .importing: "arrow.down.circle"
        case .cancelled: "xmark.circle"
        case .missing: "questionmark.folder"
        case .damaged: "exclamationmark.triangle"
        case .failed: "exclamationmark.octagon"
        }
    }

    /// What the symbol says, to VoiceOver and in its tooltip.
    public var label: LocalizedStringResource {
        switch self {
        case .ready: "Ready"
        case .off: "Not used in lookups"
        case .importing: "Importing"
        case .cancelled: "Import cancelled"
        case .missing: "File missing"
        case .damaged: "Cannot be read"
        case .failed: "Import failed"
        }
    }

    /// Under way or in trouble: a row the reader may need to act on, so a filter never hides it.
    var needsTheReader: Bool {
        switch self {
        case .ready, .off: false
        case .importing, .cancelled, .missing, .damaged, .failed: true
        }
    }
}

/// **Settings ▸ Dictionaries' filter** (UI35): name or language, case- and diacritic-blind, in the library's own
/// order; a row that needs the reader and the selected row always stay, so typing never hides a problem or the row
/// whose options are shown below.
public enum DictionaryFilter {
    public struct Item: Sendable {
        public let id: UUID
        public let name: String
        public let language: String
        public let status: DictionaryRowStatus

        public init(id: UUID, name: String, language: String, status: DictionaryRowStatus) {
            self.id = id
            self.name = name
            self.language = language
            self.status = status
        }
    }

    public static let noMatch = LocalizedStringResource("No dictionaries match.")
    public static let emptyLibrary = LocalizedStringResource("No Dictionaries Yet")

    public static func isFiltering(_ query: String) -> Bool { !words(query).isEmpty }

    /// The ids to show, in `items`' order.
    public static func visible(_ items: [Item], query: String, selection: UUID?) -> [UUID] {
        let wanted = words(query)
        guard !wanted.isEmpty else { return items.map(\.id) }
        return items.filter { item in
            if item.id == selection || item.status.needsTheReader { return true }
            let text = fold(item.name + " " + item.language)
            return wanted.allSatisfy(text.contains)
        }.map(\.id)
    }

    /// Case and diacritics folded, apostrophes dropped (so "learners" finds "Learner’s").
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "[’'ʼ]", with: "", options: .regularExpression)
    }

    static func words(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

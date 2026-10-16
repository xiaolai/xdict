import Foundation
import XDictContract
import XDictLibrary

/// **One dictionary of the library as a search sees it**: in the reader's order, with its name and edition (R11: every
/// result names its source), whether the reader uses it in lookups, and whether it can answer now — and if not, why.
public struct SearchSource: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let edition: Edition?
    /// What the reader's per-dictionary preferences are kept under (zoom, appearance): the lineage, stable across
    /// editions the reader joined (ADR-0002); the library's own id until an import has given one.
    public let preferencesKey: String
    public let enabled: Bool
    public let state: SourceState

    public init(id: UUID, name: String, edition: Edition?, preferencesKey: String, enabled: Bool, state: SourceState) {
        self.id = id
        self.name = name
        self.edition = edition
        self.preferencesKey = preferencesKey
        self.enabled = enabled
        self.state = state
    }

    /// The open handle, when the dictionary answers.
    public var handle: DictId? {
        if case .ready(let handle) = state { handle } else { nil }
    }
}

/// Whether a dictionary can answer now, and if not, why: the library's phase as the search needs it.
public enum SourceState: Hashable, Sendable {
    case ready(DictId)
    /// Queued, importing (with the share read, when the service has said), opening or stopping an import: it answers
    /// once that is done.
    case indexing(fraction: Double?)
    /// A file of it is not where it was, and its bookmark finds it nowhere.
    case missing(fileName: String)
    /// A file of it has become a link or left its folder, so it is never read.
    case outsideItsFolder(fileName: String)
    /// The file itself is the reason: unsupported, or damaged (`ImportRefusal.isPermanent`).
    case refused(ImportRefusal)
    /// The last import or open failed, or the reader cancelled it; a retry is offered.
    case notImported(ImportRefusal)
}

extension SourceState {
    /// The library's phase for one dictionary; nil (never seen this session) reads as indexing, since the library
    /// opens or imports every dictionary at launch.
    init(_ phase: EntryPhase?, handle: DictId?) {
        switch phase {
        case .ready:
            self = handle.map(SourceState.ready) ?? .indexing(fraction: nil)
        case .none, .waiting, .opening, .cancelling:
            self = .indexing(fraction: nil)
        case .importing(let done, let total):
            self = .indexing(fraction: total > 0 ? min(1, Double(done) / Double(total)) : nil)
        case .cancelled:
            self = .notImported(.cancelled)
        case .refused(let why):
            self = .refused(why)
        case .failed(let why):
            self = .notImported(why)
        case .missing(let name):
            self = .missing(fileName: name)
        case .outsideItsFolder(let name):
            self = .outsideItsFolder(fileName: name)
        }
    }
}

extension Library {
    /// Every dictionary of the library, in the reader's order, as the search sees it. Reading it in a view observes the
    /// library's entries and phases, so the window follows every change.
    public var searchSources: [SearchSource] {
        entries.map { entry in
            SearchSource(id: entry.id, name: entry.displayName, edition: entry.edition,
                         preferencesKey: entry.preferencesKey, enabled: entry.enabled,
                         state: SourceState(phases[entry.id], handle: handle(entry.id)))
        }
    }
}

import Foundation
import XDictContract

/// Which dictionaries a search asks: every enabled one, in the reader's order (Q2), or one (Q1).
public enum SearchScope: Hashable, Sendable {
    case all
    case one(UUID)
}

/// One result: a record of one dictionary (ADR-0007 decision 2: the reference is the only form stored).
public struct ResultID: Hashable, Sendable {
    public let dictionary: UUID
    public let entry: EntryRef

    public init(dictionary: UUID, entry: EntryRef) {
        self.dictionary = dictionary
        self.entry = entry
    }
}

/// **One place in the reader's trail** (I7, I8): what was looked up and how, the entry read there, and how far down it
/// the reader had scrolled when they left it.
public struct Visit: Hashable, Sendable {
    public var query: String
    public var mode: MatchMode
    public var scope: SearchScope
    /// The entry read here; nil while none is.
    public var result: ResultID?
    /// Where the reader had scrolled to, in CSS pixels from the top, when they left.
    public var scroll: Double
    /// The anchor a link named, to scroll to on first arrival.
    public var anchor: String?
    /// What the reader had typed in the search field here, whose list the sidebar shows; nil for a link followed.
    public var typed: String?
    /// A word the reader typed, which "return to the original word" goes back to; a link followed is not one.
    public var isOrigin: Bool

    public init(query: String, mode: MatchMode, scope: SearchScope, result: ResultID? = nil, scroll: Double = 0,
                anchor: String? = nil, typed: String? = nil, isOrigin: Bool) {
        self.query = query
        self.mode = mode
        self.scope = scope
        self.result = result
        self.scroll = scroll
        self.anchor = anchor
        self.typed = typed
        self.isOrigin = isOrigin
    }
}

/// **The reader's trail**: every typed word and every link followed, in order, with Back and Forward over it and a way
/// to the word the reader typed last (I8: "return to the original word"). Choosing another result of the same lookup
/// replaces the place, as a list's selection does; a new lookup or a link adds one, dropping what lay ahead, as a
/// browser does. Bounded, so a long session keeps the most recent places.
public struct Trail: Hashable, Sendable {
    public static let capacity = 500

    public private(set) var visits: [Visit] = []
    /// The current place, -1 when the trail is empty.
    public private(set) var index = -1

    public init() {}

    public var current: Visit? { visits.indices.contains(index) ? visits[index] : nil }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index + 1 < visits.count }

    /// The last typed word at or before the current place.
    public var originIndex: Int? {
        guard index >= 0 else { return nil }
        return visits[...index].lastIndex(where: \.isOrigin)
    }

    public var canReturnToOrigin: Bool { originIndex.map { $0 != index } ?? false }

    /// A new place after the current one; what lay ahead is dropped.
    public mutating func push(_ visit: Visit) {
        if index + 1 < visits.count { visits.removeSubrange((index + 1)...) }
        visits.append(visit)
        if visits.count > Self.capacity { visits.removeFirst(visits.count - Self.capacity) }
        index = visits.count - 1
    }

    public mutating func updateCurrent(_ change: (inout Visit) -> Void) {
        guard visits.indices.contains(index) else { return }
        change(&visits[index])
    }

    public mutating func back() -> Visit? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    public mutating func forward() -> Visit? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }

    /// To the last typed word at or before the current place, in one step; the places after it stay ahead.
    public mutating func toOrigin() -> Visit? {
        guard canReturnToOrigin, let origin = originIndex else { return nil }
        index = origin
        return current
    }
}

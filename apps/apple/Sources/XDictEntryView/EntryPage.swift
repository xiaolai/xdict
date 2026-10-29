import Foundation

/// **One dictionary's part of the All page** (Apple Dictionary parity P15; ADR-0010 amendment of 2026-10-18): its entry,
/// from its own content, in a frame of its own. `id` is the window's name for the dictionary (the library's), handed
/// back when a link or a sound in this frame is followed; `name` is what its divider says.
public struct EntryPageItem: Sendable {
    public let id: UUID
    public let name: String
    public let content: any EntryContent
    public let reference: EntryReference

    public init(id: UUID, name: String, content: any EntryContent, reference: EntryReference) {
        self.id = id
        self.name = name
        self.content = content
        self.reference = reference
    }

    /// What makes two items the same frame: the same dictionary, open under the same binding, showing the same record.
    /// A frame whose identity holds is kept as it is when the page is shown again (another dictionary answered).
    var identity: Identity { Identity(id: id, binding: content.binding, reference: reference) }

    struct Identity: Hashable {
        let id: UUID
        let binding: EntryBinding
        let reference: EntryReference
    }
}

/// **A frame named by what it shows** (HIG audit UI11): the dictionary's open handle, the edition its documents come
/// from, and the record. An answer's evidence is revealed only in the one frame its frozen target names.
public struct EntryFrameName: Hashable, Sendable {
    public let handle: String
    public let edition: String
    public let reference: EntryReference

    public init(handle: String, edition: String, reference: EntryReference) {
        self.handle = handle
        self.edition = edition
        self.reference = reference
    }
}

/// One dictionary on the All page, as the window's jump list names it (HIG audit UI24).
public struct EntryPageSource: Hashable, Sendable {
    public let id: UUID
    public let name: String
}

/// **The All page's dictionaries and the one being read** (HIG audit UI24): every section in the reader's order, the
/// one at the view's top, and whether its name must be pinned there because its own header has scrolled away.
public struct EntryPageSources: Equatable, Sendable {
    public let sources: [EntryPageSource]
    public let current: UUID?
    public let pinned: Bool

    /// The current dictionary's name, for the pinned label.
    public var currentName: String? { sources.first { $0.id == current }?.name }
}

/// Where the page is shown: the main window (Apple's page: paper, collapsible dividers following the text size), or
/// the lookup popover (P41; owner, 2026-10-18: "stack every dictionary as a section, like Apple's"): no paper of its
/// own on the glass, every section named by Apple's compact popover divider, nothing collapsed.
public enum EntryPageStyle: Sendable {
    case window
    case popover

    /// The popover's page is the one whose frame takes the panel layer.
    init(frame: EntryReadingFrame) { self = frame.contains(.panel) ? .popover : .window }
}

/// **The page's arithmetic, with no view** (P15): which sections have a divider, which are collapsed, and which frames
/// to make now. A web view per dictionary costs a content process, so a headword found in many dictionaries makes only
/// the frames on screen and one screen beyond; the rest are made as the reader scrolls towards them, or all at once for
/// find.
enum EntryPagePlan {
    /// The height a frame not yet made is laid out at, in points: an entry's usual first screen, so the page's length
    /// and its scroller are roughly right before the frames below are made.
    static let estimatedHeight: Double = 240
    /// How far below the visible part of the page frames are made ahead of the reader, in viewports.
    static let lookahead: Double = 1

    /// Apple's page: every section but the first has a divider (the first dictionary is read straight after the
    /// toolbar). A collapsed first section needs its divider back, or nothing could expand it.
    /// **A first section whose frame could not show its entry keeps its divider too** (owner, 2026-10-29: a page opened
    /// on a word whose first dictionary could not answer showed a tall blank where the entry belongs, and, with no
    /// divider, nothing named it). A blank band is never anonymous.
    /// In the lookup popover every section has one: its title row is the headword, so the first dictionary is named
    /// by its divider too, as Apple's popover names each of its stacked dictionaries (P41).
    static func hasDivider(at index: Int, collapsed: Bool, style: EntryPageStyle = .window,
                           failed: Bool = false) -> Bool {
        style == .popover || index > 0 || collapsed || failed
    }

    /// The sections whose frames should exist for a viewport from `top` to `top + height` (points, the page's
    /// coordinates). `tops` and `heights` are each section's frame top and current height; a collapsed section's frame
    /// is never made for scrolling (it is hidden), only for find.
    static func wanted(tops: [Double], heights: [Double], collapsed: [Bool], top: Double, height: Double) -> Set<Int> {
        let bottom = top + height * (1 + lookahead)
        var out: Set<Int> = []
        for index in tops.indices where !collapsed[index] {
            let start = tops[index], end = start + heights[index]
            if end >= top && start <= bottom { out.insert(index) }
        }
        return out
    }

    /// The frame Tab reaches from the results (the key-view order): the first expanded, made frame whose bottom is below
    /// `top`, the page's scroll position; else the first expanded, made frame; nil when none is made.
    static func firstKeyFrame(tops: [Double], heights: [Double], collapsed: [Bool], made: [Bool], top: Double) -> Int? {
        let usable = tops.indices.filter { !collapsed[$0] && made[$0] }
        return usable.first { tops[$0] + heights[$0] > top } ?? usable.first
    }

    /// Where a find match lands in the page: the global position `(section, match)` after stepping from `current`, over
    /// sections with `counts` matches each, wrapping; nil when nothing matches anywhere.
    static func step(from current: (section: Int, match: Int)?, counts: [Int], forward: Bool) -> (section: Int, match: Int)? {
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        let offsets = counts.indices.map { counts[..<$0].reduce(0, +) }
        let global = current.map { offsets[$0.section] + $0.match }
        let next = global.map { (($0 + (forward ? 1 : -1)) % total + total) % total } ?? (forward ? 0 : total - 1)
        guard let section = counts.indices.last(where: { offsets[$0] <= next && counts[$0] > 0 }) else { return nil }
        return (section, next - offsets[section])
    }

    /// **The one frame a name picks** (UI11): exactly one frame must carry it; none, or two, reveal nothing, so evidence
    /// is never shown in a frame it was not quoted from.
    static func frame(named name: EntryFrameName, among frames: [EntryFrameName]) -> Int? {
        let matches = frames.indices.filter { frames[$0] == name }
        return matches.count == 1 ? matches[0] : nil
    }

    /// **The section being read** (UI24): the last whose start (its divider's top, or the first frame's top) is at or
    /// above the view's top `top`; nil on an empty page. Half a point of slack: a jump lands exactly on a start.
    static func current(starts: [Double], top: Double) -> Int? {
        guard !starts.isEmpty else { return nil }
        return starts.indices.last { starts[$0] <= top + 0.5 } ?? 0
    }

    /// Whether the current section's name is pinned at the view's top (UI24): on the window's page of more than one
    /// dictionary, once that section's own header has scrolled above the view. The popover names every section.
    static func pinsSource(current: Int, starts: [Double], top: Double, style: EntryPageStyle) -> Bool {
        style == .window && starts.count > 1 && starts.indices.contains(current) && starts[current] < top - 0.5
    }

    /// The 1-based position of `current` among every match of the page, for the find bar.
    static func position(_ current: (section: Int, match: Int)?, counts: [Int]) -> Int {
        guard let current else { return 0 }
        return counts[..<current.section].reduce(0, +) + current.match + 1
    }
}

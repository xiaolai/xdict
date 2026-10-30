import Foundation

/// **Which dictionaries the lookup popup stacks, and in what order — and which ones a hover uses** (owner, 2026-10-29:
/// "鼠标取词 popup 里词典的选择与顺序, 是不是应该在 settings 里有设置啊？"; split in two, owner, 2026-10-30: "hover's own
/// order (default to inherite from dictionary order, and users can change it for popup)"). The window keeps its list and
/// order (Settings ▸ Dictionaries: "Use in lookups", drag to reorder); the popup has a second, because a panel at the
/// pointer has room for a few frames and a thesaurus leading every hover is noise, not preference; and **hover has a
/// third of its own**, which until the reader changes it follows the dictionaries' own order — a hover should surprise
/// nobody who has not asked for something different.
///
/// **Two stored things make each list total**: `order`, the dictionaries the reader put in that list, in their order; and
/// `excluded`, the ones they took out. A dictionary they never touched — a new import — joins at the end of its library
/// order, as Apple's popover would show it; one they removed stays out until they put it back. Ids the library no longer
/// has are dropped on the way out, and a repeated id counts once. Every list empty reads as "the library's order", which
/// is hover's default and the popup's.
public enum PopupPreferences {
    /// **The two lists, one meaning each.** `popup` serves the popup whatever opened it but a hover — the shortcut, the
    /// Service, the menu; `hover` serves a pointer hover. The keys are fixed: `hoverPopup.*` is where readers' popup lists
    /// have lived since 2026-10-29, and moving them would lose the order they chose.
    public enum List: String, Sendable, CaseIterable {
        case popup, hover

        var orderKey: String { self == .popup ? "hoverPopup.order" : "hover.order" }
        var excludedKey: String { self == .popup ? "hoverPopup.excluded" : "hover.excluded" }
    }

    /// Posted when the reader saves a list: the open popover asks its dictionaries again (audit 2026-10-29).
    public static let changed = Notification.Name("PopupPreferences.changed")
    public static let orderKey = "hoverPopup.order"
    public static let excludedKey = "hoverPopup.excluded"

    /// The list's dictionaries, in order, from those available (the library's enabled ones).
    public static func ordered(_ available: [UUID], list: List = .popup,
                               defaults: UserDefaults = .standard) -> [UUID] {
        let present = Set(available)
        let excluded = Set(strings(list.excludedKey, defaults).compactMap(UUID.init))
        var seen: Set<UUID> = []
        var out: [UUID] = []
        for id in strings(list.orderKey, defaults).compactMap(UUID.init)
        where present.contains(id) && !excluded.contains(id) && seen.insert(id).inserted {
            out.append(id)
        }
        for id in available where !seen.contains(id) && !excluded.contains(id) {
            out.append(id)
        }
        return out
    }

    /// The reader chose this list, in this order: whatever of `available` it leaves out is out until they put it back.
    ///
    /// **A dictionary the library is not offering right now keeps what it had** (audit 2026-10-29): it may be disabled
    /// rather than gone, and rebuilding both lists from the enabled set alone erased its place — so a dictionary the
    /// reader had taken out came back the day it was enabled again, and one they had ordered lost its place for being
    /// off. Only an id the caller hands over is treated as the whole truth; the rest is carried through.
    public static func set(_ chosen: [UUID], available: [UUID], list: List = .popup,
                           defaults: UserDefaults = .standard) {
        let present = Set(available)
        var seen: Set<UUID> = []
        let kept = chosen.filter { present.contains($0) && seen.insert($0).inserted }
        let staleOrder = strings(list.orderKey, defaults).compactMap(UUID.init).filter { !present.contains($0) }
        var staleSeen: Set<UUID> = []
        let carried = staleOrder.filter { staleSeen.insert($0).inserted }
        let staleExcluded = strings(list.excludedKey, defaults).compactMap(UUID.init)
            .filter { !present.contains($0) && !staleSeen.contains($0) }
        defaults.set((kept + carried).map(\.uuidString), forKey: list.orderKey)
        defaults.set((available.filter { !seen.contains($0) } + staleExcluded).map(\.uuidString), forKey: list.excludedKey)
        // **After both lists are written** (verification round 2): an observer that re-reads synchronously must see the
        // new list, not the one this call is replacing.
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func strings(_ key: String, _ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }
}

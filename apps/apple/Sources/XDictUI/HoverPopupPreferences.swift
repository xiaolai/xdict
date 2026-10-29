import Foundation

/// **Which dictionaries the hover popup stacks, and in what order** (owner, 2026-10-29: "鼠标取词 popup 里词典的选择与顺序,
/// 是不是应该在 settings 里有设置啊？" — yes: its own list, ADR-0012's amendment of that day). The window keeps its list
/// and order (Settings ▸ Dictionaries: "Use in lookups", drag to reorder); the popover has a second, because a panel at
/// the pointer has room for a few frames and a thesaurus leading every hover is noise, not preference.
///
/// **Two stored things make the rule total**: `order`, the dictionaries the reader put in the popup, in their order; and
/// `excluded`, the ones they took out. A dictionary they never touched — a new import — joins at the end of its library
/// order, as Apple's popover would show it; one they removed stays out until they put it back. Ids the library no longer
/// has are dropped on the way out, and a repeated id counts once.
public enum HoverPopupPreferences {
    /// Posted when the reader saves the popup's list: the open popover asks its dictionaries again (audit 2026-10-29).
    public static let changed = Notification.Name("HoverPopupPreferences.changed")
    public static let orderKey = "hoverPopup.order"
    public static let excludedKey = "hoverPopup.excluded"

    /// The popup's dictionaries, in order, from those available (the library's enabled ones).
    public static func ordered(_ available: [UUID], defaults: UserDefaults = .standard) -> [UUID] {
        let present = Set(available)
        let excluded = Set(strings(excludedKey, defaults).compactMap(UUID.init))
        var seen: Set<UUID> = []
        var out: [UUID] = []
        for id in strings(orderKey, defaults).compactMap(UUID.init)
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
    public static func set(_ chosen: [UUID], available: [UUID], defaults: UserDefaults = .standard) {
        let present = Set(available)
        var seen: Set<UUID> = []
        let kept = chosen.filter { present.contains($0) && seen.insert($0).inserted }
        let staleOrder = strings(orderKey, defaults).compactMap(UUID.init).filter { !present.contains($0) }
        var staleSeen: Set<UUID> = []
        let carried = staleOrder.filter { staleSeen.insert($0).inserted }
        let staleExcluded = strings(excludedKey, defaults).compactMap(UUID.init)
            .filter { !present.contains($0) && !staleSeen.contains($0) }
        defaults.set((kept + carried).map(\.uuidString), forKey: orderKey)
        defaults.set((available.filter { !seen.contains($0) } + staleExcluded).map(\.uuidString), forKey: excludedKey)
        // **After both lists are written** (verification round 2): an observer that re-reads synchronously must see the
        // new list, not the one this call is replacing.
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func strings(_ key: String, _ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }
}

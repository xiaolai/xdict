import Foundation

/// **When the panel takes a measured height** (Codex's UX decision §3): not for a change under 2 pt (no
/// oscillation), not from an entry no longer shown. (The reader's own size went with the resizable panel: the popover
/// is not resizable, P41.)
public struct PanelFit: Sendable {
    public static let threshold: Double = 2
    private var entry = 0

    public init() {}

    /// A new entry is being shown; `entry` names it.
    public mutating func began(entry: Int) { self.entry = entry }

    public func accepts(height: Double, current: Double, entry: Int) -> Bool {
        entry == self.entry && abs(height - current) >= Self.threshold
    }
}

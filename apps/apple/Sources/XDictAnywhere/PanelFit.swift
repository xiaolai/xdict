import Foundation

/// **When the panel takes a measured height** (Codex's UX decision §3): not for a change under 2 pt (no
/// oscillation), not from an entry no longer shown, and never once the reader has resized the panel, until it is
/// dismissed.
public struct PanelFit: Sendable {
    public static let threshold: Double = 2
    private var entry = 0
    private var readerSized = false

    public init() {}

    /// A new entry is being shown; `entry` names it.
    public mutating func began(entry: Int) { self.entry = entry }
    public mutating func readerResized() { readerSized = true }
    public mutating func dismissed() { readerSized = false }

    public func accepts(height: Double, current: Double, entry: Int) -> Bool {
        !readerSized && entry == self.entry && abs(height - current) >= Self.threshold
    }
}

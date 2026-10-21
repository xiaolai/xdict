import AppKit

/// **Which click asks for the menu** (ported from XiaolaiDict, plan-history-and-learning §4), decided apart from AppKit so
/// both answers are tests. A right click — and a control-click, which is the system's rule and not a courtesy: a reader on
/// a trackpad with secondary click switched off has no other way to the menu.
public enum StatusItemClick {
    public static func isSecondary(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseDown, .rightMouseUp: return true
        default: return event.modifierFlags.contains(.control)
        }
    }
}

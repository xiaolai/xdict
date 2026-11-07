import Observation

/// **A value kept in step with the observable state it is read from**, for a place SwiftUI does not draw — an AppKit
/// property such as a status item's tooltip (L14). Observation fires once per registration, so each change registers
/// the next; `apply` hears the value now and after every change.
public enum Observed {
    @MainActor
    public static func follow(_ read: @escaping @MainActor @Sendable () -> String,
                              apply: @escaping @MainActor @Sendable (String) -> Void) {
        let value = withObservationTracking { read() } onChange: {
            Task { @MainActor in follow(read, apply: apply) }
        }
        apply(value)
    }
}

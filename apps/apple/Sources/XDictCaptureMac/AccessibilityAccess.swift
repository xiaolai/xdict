import ApplicationServices

/// What a permission probe found, **three-valued because two values are what caused the defect** (moved from
/// XiaolaiDict's `PermissionProbe`). `granted` and `declined` are claims about the reader's consent; `couldNotTell` is a
/// claim about the probe, and folding it into either neighbour is wrong in a way that shows: folded into `declined` it
/// invites a prompt that grants nothing, folded into `granted` it promises a capture that then fails.
public enum PermissionProbe: Sendable, Equatable {
    case granted
    /// The reader said no, or has not said yes.
    case declined
    /// The probe failed for a reason that is not a refusal, so it says nothing about consent.
    case couldNotTell
}

/// **Whether XDict may read other apps through Accessibility, asked and never prompted** (XDict ADR-0014 decision 7;
/// moved from XiaolaiDict's `AccessibilityAccess`, its asking half left behind). Capture reads this on every read, a
/// hover's included, and a dialog there would be attached to nothing the reader asked for. Asking belongs to the setup
/// row and the shortcut, through `AccessibilityGate` in the composition layer; this type has no way to ask at all, and
/// `theHoverGateNeverPrompts` holds the target to binding none.
///
/// Synchronous: `AXIsProcessTrusted()` answers in-process and cannot fail, which is also why `couldNotTell` does not
/// arise from the system probe today. It is carried rather than collapsed, so a gate written as `!= .granted` cannot
/// come to read a third state as a refusal.
public struct AccessibilityAccess: Sendable {
    private let probe: @Sendable () -> PermissionProbe

    public init(probe: @escaping @Sendable () -> PermissionProbe) {
        self.probe = probe
    }

    public static let system = AccessibilityAccess(probe: { AXIsProcessTrusted() ? .granted : .declined })

    /// What the probe found now. Never a stored "asked" flag: after a reset, a denial or a restart the answer is the
    /// system's, read again.
    public func state() -> PermissionProbe { probe() }

    /// Whether a read may go ahead: only on a grant, never on `couldNotTell`.
    public func granted() -> Bool { probe() == .granted }
}

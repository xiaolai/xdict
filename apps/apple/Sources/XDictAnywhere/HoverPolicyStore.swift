import Foundation
import XDictCapture

/// **The hover policy, kept across launches** (ported from XiaolaiDict's `HoverPolicyStore`, plan-capture WI-3): the key,
/// the gesture, the rest and the reader's excluded apps and sites, stored as one encoded value — a half-applied policy (a
/// new key with the old exclusions) is a state no reader asked for.
///
/// **What it never trusts**: a stored policy that has lost the password managers gets them back (a rule, not a
/// preference: capture always takes the sentence around a word); and the scripts are never stored or read back — they
/// are derived from the enabled dictionaries' languages each time (`HoverScripts`, ADR-0014 d.10).
public struct HoverPolicyStore {
    public static let defaultsKey = "HoverPolicy"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Unreadable is `.shipped`, never a failure and never an empty policy.
    public func load() -> HoverPolicy {
        guard let data = defaults.object(forKey: Self.defaultsKey) as? Data,
              var stored = try? JSONDecoder().decode(HoverPolicy.self, from: data)
        else { return .shipped }
        stored.excludedApps.formUnion(HoverPolicy.defaultExcludedApps)
        stored.allowedScripts = nil
        // A rest that is not exactly one of the choices is the shipped rest: what the picker shows, and what the gate
        // waits (`HoverControl.settle`). Never the nearest: arithmetic on a stored value can trap.
        if HoverPolicy.Settle(rawValue: stored.settleMilliseconds) == nil {
            stored.settleMilliseconds = HoverPolicy.shipped.settleMilliseconds
        }
        return stored
    }

    public func save(_ policy: HoverPolicy) {
        var stored = policy
        stored.allowedScripts = nil
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

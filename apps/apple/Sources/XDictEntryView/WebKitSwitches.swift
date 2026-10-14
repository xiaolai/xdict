import Foundation
import WebKit

/// WebKit's internal feature flags, as the entry view needs them: listed, set, and read back. The real host is
/// `WKPreferences` through SPI; tests and the lab's fault injection give their own.
@MainActor
public protocol WebKitFeatureSwitches {
    /// Every feature by its key; nil when the list itself cannot be had.
    func features() -> [String: AnyObject]?
    /// Whether a feature can be set at all.
    var canSet: Bool { get }
    /// Whether a feature's state can be read back.
    var canRead: Bool { get }
    func setEnabled(_ enabled: Bool, _ feature: AnyObject)
    func isEnabled(_ feature: AnyObject) -> Bool
}

/// **The two switches the entry view will not render without** (ADR-0009 decision 7): `LinkPreconnect` (a scripted
/// click on a remote `<a>` opens TCP, TLS and DNS before any delegate is asked, and nothing public stops it) and
/// `PeerConnectionEnabled` (WebRTC's STUN, TURN and mDNS pass every public layer). **Turned off, then read back, on the
/// very preferences the web view is made with; fail closed** — a list, a feature, a setter or a getter that is missing,
/// or a switch still on after it was turned off, refuses rendering with a sentence that names it (refutation of
/// ADR-0009, item 5).
public enum EntrySwitches {
    public static let required = ["LinkPreconnect", "PeerConnectionEnabled"]

    /// What turning `required` off on `host` came to: each switch read back off, or the reason to refuse.
    @MainActor
    public static func turnOff(_ required: [String] = required,
                               on host: any WebKitFeatureSwitches) -> Result<[String: Bool], EntryRefusal> {
        guard let features = host.features() else { return .failure(.switchMissing("+[WKPreferences _features]")) }
        guard host.canSet else { return .failure(.switchMissing("-[WKPreferences _setEnabled:forFeature:]")) }
        guard host.canRead else { return .failure(.switchUnverifiable("-[WKPreferences _isEnabledForFeature:]")) }
        var found: [(String, AnyObject)] = []
        for key in required {
            guard let feature = features[key] else { return .failure(.switchMissing(key)) }
            found.append((key, feature))
        }
        var readBack: [String: Bool] = [:]
        for (key, feature) in found {
            host.setEnabled(false, feature)
            let enabled = host.isEnabled(feature)
            guard !enabled else { return .failure(.switchStillOn(key)) }
            readBack[key] = enabled
        }
        return .success(readBack)
    }
}

/// The switches of one `WKPreferences`, reached through WebKit's SPI by name. Every selector is asked for before it is
/// called, so a WebKit that renamed one answers "missing" instead of crashing (spike 3 named them from the running
/// system: `introspect-build-mac.txt`).
@MainActor
public struct PreferencesSwitches: WebKitFeatureSwitches {
    public let preferences: WKPreferences

    public init(_ preferences: WKPreferences) {
        self.preferences = preferences
    }

    static let list = NSSelectorFromString("_features")
    static let key = NSSelectorFromString("key")
    static let set = NSSelectorFromString("_setEnabled:forFeature:")
    static let get = NSSelectorFromString("_isEnabledForFeature:")

    public func features() -> [String: AnyObject]? {
        let type: AnyObject = WKPreferences.self
        guard type.responds(to: Self.list),
              let listed = type.perform(Self.list)?.takeUnretainedValue() as? [NSObject] else { return nil }
        var byKey: [String: AnyObject] = [:]
        for feature in listed where feature.responds(to: Self.key) {
            if let name = feature.perform(Self.key)?.takeUnretainedValue() as? String { byKey[name] = feature }
        }
        return byKey
    }

    public var canSet: Bool { preferences.responds(to: Self.set) }
    public var canRead: Bool { preferences.responds(to: Self.get) }

    public func setEnabled(_ enabled: Bool, _ feature: AnyObject) {
        typealias Setter = @convention(c) (NSObject, Selector, Bool, NSObject) -> Void
        guard let feature = feature as? NSObject, let method = preferences.method(for: Self.set) else { return }
        unsafeBitCast(method, to: Setter.self)(preferences, Self.set, enabled, feature)
    }

    public func isEnabled(_ feature: AnyObject) -> Bool {
        typealias Getter = @convention(c) (NSObject, Selector, NSObject) -> Bool
        // No getter, or no feature object, reads as "still on": fail closed.
        guard let feature = feature as? NSObject, let method = preferences.method(for: Self.get) else { return true }
        return unsafeBitCast(method, to: Getter.self)(preferences, Self.get, feature)
    }
}

/// **Whether entries can be shown on this Mac, asked at launch** (ADR-0009 decision 7: "read back at launch"): the two
/// switches turned off and read back on a fresh `WKPreferences`, which makes no web view and loads nothing. Every web
/// view asks again of its own preferences before it is made (`EntryPane.gate`).
public enum EntryReadiness {
    @MainActor
    public static func check() -> Result<[String: Bool], EntryRefusal> {
        EntrySwitches.turnOff(on: PreferencesSwitches(WKPreferences()))
    }
}

import Foundation

/// **The confinement layers of an entry's web view** (ADR-0009 decision 7, decided by the owner 2026-10-14). Every one is
/// required: the app only ever uses `production`. The other values exist for one purpose, the hostile-input suite's
/// isolated per-layer controls (plan-macos-v1 WI-4: each layer shown to let an attempt out when it alone is off, and to
/// stop it when on), and only the development lab builds them — `package` access, and the lab's `--disable-layer` flag
/// is in the lab alone, which never ships in XDict.app (`Tools/build-bundle.sh` refuses a bundle carrying it).
public struct EntryConfinement: Hashable, Sendable {
    /// The core's policy as a `Content-Security-Policy` header on every response the scheme handler gives.
    public let policyHeader: Bool
    /// The `WKContentRuleList` (`EntryRuleList`).
    public let ruleList: Bool
    /// The navigation table (`EntryNavigationPolicy`): off, every navigation is allowed and nothing is routed.
    public let navigationPolicy: Bool
    /// No new window: scripts may not open one by themselves, and the UI delegate creates no web view for one.
    public let refusesNewWindows: Bool
    /// The WebKit switches turned off and read back before anything renders (`EntrySwitches`).
    public let featuresOff: [String]

    public static let production = EntryConfinement(policyHeader: true, ruleList: true, navigationPolicy: true,
                                                    refusesNewWindows: true, featuresOff: EntrySwitches.required)

    package init(policyHeader: Bool, ruleList: Bool, navigationPolicy: Bool, refusesNewWindows: Bool,
                 featuresOff: [String]) {
        self.policyHeader = policyHeader
        self.ruleList = ruleList
        self.navigationPolicy = navigationPolicy
        self.refusesNewWindows = refusesNewWindows
        self.featuresOff = featuresOff
    }

    /// Whether this is the whole production configuration: every layer, both switches.
    public var isProduction: Bool { self == .production }
}

/// Why the entry view will not render, each its own sentence (`EntrySentences.refusal`).
public enum EntryRefusal: Error, Hashable, Sendable {
    /// A switch, the list of them, or the means to set one is missing from this WebKit.
    case switchMissing(String)
    /// A switch cannot be read back, so its state is unknown.
    case switchUnverifiable(String)
    /// A switch was turned off and reads back on.
    case switchStillOn(String)
    /// The rule list could not be compiled.
    case ruleListUnavailable(String)
    /// The document came with no policy to enforce.
    case noPolicy
}

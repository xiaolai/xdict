import Foundation
import XDictBase

/// **One preference domain's contents, as read** (plan-setup-v2 WI-5): a value tree the probes can be written against
/// without an `Any` crossing a concurrency boundary, and without a test needing the system's own preferences.
public enum PlistValue: Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case string(String)
    case array([PlistValue])
    case dictionary([String: PlistValue])
    /// A type no probe expects (data, a date, …): read, and unreadable for whatever fact wanted it.
    case other

    public init(_ value: Any) {
        let object = value as AnyObject
        // **The CoreFoundation type first**: an `NSNumber` also casts to `Bool` in Swift, so a CFBoolean and the
        // integer 1 would otherwise be the same value here.
        if CFGetTypeID(object) == CFBooleanGetTypeID(), let number = object as? NSNumber {
            self = .bool(number.boolValue)
        } else if let number = object as? NSNumber {
            let double = number.doubleValue
            self = double == double.rounded(.towardZero) && abs(double) < 9e15 ? .integer(number.intValue) : .real(double)
        } else if let text = object as? String {
            self = .string(text)
        } else if let list = object as? [Any] {
            self = .array(list.map(PlistValue.init))
        } else if let table = object as? [String: Any] {
            self = .dictionary(table.mapValues(PlistValue.init))
        } else {
            self = .other
        }
    }

    /// A switch's value. `defaults` writes a boolean as `0`/`1` in several of these domains, so both readings are the
    /// same fact; anything else is nil, and the caller says "unreadable" rather than guess.
    public var switchValue: Bool? {
        switch self {
        case .bool(let on): on
        case .integer(0): false
        case .integer(1): true
        default: nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value): value
        case .real(let value) where value == value.rounded(): Int(exactly: value)
        default: nil
        }
    }

    public subscript(key: String) -> PlistValue? {
        if case .dictionary(let table) = self { return table[key] }
        return nil
    }
}

/// **The system facts the board cannot learn from an API SwiftUI observes** (plan-setup-v2 WI-5): whether the
/// `Look Up in XDict` Service is switched on in `pbs`, Apple's Look Up shortcut and three-finger tap, and which of
/// Apple's own dictionaries Dictionary.app has active.
///
/// **Read-only, and it stays that way**: nothing here has a setter, and every read goes through
/// `CFPreferencesCopyMultiple`, which reads. The reader changes the system, in System Settings, through the buttons the
/// row offers.
///
/// **All four formats are undocumented.** A domain that cannot be read, a key that is missing, a value of an
/// unexpected type — each is `.unreadable`, which the row draws as "check" and never as done: a green row over a guess
/// is worse than an honest question.
public struct SystemProbes: Sendable {
    /// The Service's `NSMessage` in `Info.plist`, and the second half of its `pbs` key.
    public static let serviceName = "lookUpInXDict"
    /// Apple's symbolic hotkey for Look Up in Dictionary.
    public static let symbolichotkeyLookUp = "70"
    /// The trackpad domains that can hold the three-finger tap, the built-in one and the Bluetooth driver's.
    public static let trackpadDomains = ["com.apple.AppleMultitouchTrackpad",
                                         "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    /// Where macOS installs the dictionaries Dictionary.app downloads; an entry under it is Apple's.
    public static let assetsPath = "/System/Library/AssetsV2/"
    public static let appleDictionaryPrefix = "com.apple.dictionary."

    /// Reads one domain's whole contents; nil when the domain holds nothing this reader can read.
    private let domain: @Sendable (String) -> PlistValue?

    public init(domain: @escaping @Sendable (String) -> PlistValue?) {
        self.domain = domain
    }

    /// The system's own preferences, read as the app reads them.
    public static let live = SystemProbes(domain: SystemProbes.readDomain)

    /// One domain, user-scoped and host-independent: the same read for every host and every user of this Mac.
    /// **A domain with no keys is nil, not an empty dictionary**: `CFPreferencesCopyMultiple` answers an empty table for
    /// a domain that does not exist, and the probes must tell "no such trackpad" from "a trackpad that says nothing".
    public static func readDomain(_ name: String) -> PlistValue? {
        let contents = CFPreferencesCopyMultiple(nil, name as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let value = PlistValue(contents)
        if case .dictionary(let table) = value, table.isEmpty { return nil }
        return value
    }

    /// The board's two probe-backed rows, read together.
    public struct Reading: Equatable, Sendable {
        public let services: SystemFact
        public let appleLookUp: AppleLookUp
    }

    public func read() -> Reading {
        Reading(services: Self.services(in: domain("pbs")),
                appleLookUp: AppleLookUp(
                    shortcut: Self.symbolicLookUp(in: domain("com.apple.symbolichotkeys")),
                    trackpad: Self.threeFingerTap(domains: Self.trackpadDomains.map { domain($0) }),
                    dictionaries: Self.activeAppleDictionaries(in: domain("com.apple.DictionaryServices"))))
    }

    // MARK: - The Service

    /// `pbs` ▸ `NSServicesStatus` ▸ `"<bundle>/lookUpInXDict"` ▸ `enabled_services_menu`: the Services menu's switch.
    /// A service macOS has never recorded is not a service that is off, so the key's absence is `.unreadable`.
    public static func services(in pbs: PlistValue?) -> SystemFact {
        guard let entry = pbs?["NSServicesStatus"]?["\(XDictIdentity.app)/\(serviceName)"],
              let enabled = entry["enabled_services_menu"]?.switchValue else { return .unreadable }
        return enabled ? .ready : .waiting(count: nil)
    }

    // MARK: - Apple's Look Up

    /// `com.apple.symbolichotkeys` ▸ `AppleSymbolicHotKeys` ▸ `"70"` ▸ `enabled`. Off is what XDict wants.
    /// **A key that is not there is not an answer**: macOS keeps only the shortcuts the reader has touched.
    public static func symbolicLookUp(in domain: PlistValue?) -> SystemFact {
        guard let enabled = domain?["AppleSymbolicHotKeys"]?[symbolichotkeyLookUp]?["enabled"]?.switchValue else {
            return .unreadable
        }
        return enabled ? .waiting(count: nil) : .ready
    }

    /// `TrackpadThreeFingerTapGesture` in each trackpad domain: `0` is off. A domain that is not there is a trackpad
    /// this Mac does not have and is skipped; a domain there whose key is missing or mistyped is unreadable, and an
    /// unreadable domain with nothing on elsewhere is unreadable rather than green.
    public static func threeFingerTap(domains: [PlistValue?]) -> SystemFact {
        var read = 0, unreadable = false
        for domain in domains {
            guard let domain else { continue }  // no such device on this Mac
            read += 1
            guard let gesture = domain["TrackpadThreeFingerTapGesture"]?.intValue else {
                unreadable = true
                continue
            }
            if gesture != 0 { return .waiting(count: nil) }
        }
        guard read > 0 else { return .unreadable }
        return unreadable ? .unreadable : .ready
    }

    /// `com.apple.DictionaryServices` ▸ `DCSActiveDictionaries`: an array of paths and identifiers, one per dictionary
    /// Dictionary.app has active. Apple's are the ones under the AssetsV2 install path or named `com.apple.dictionary.`.
    public static func activeAppleDictionaries(in domain: PlistValue?) -> SystemFact {
        guard case .array(let entries)? = domain?["DCSActiveDictionaries"] else { return .unreadable }
        var count = 0
        for entry in entries {
            guard case .string(let text) = entry else { return .unreadable }
            if text.hasPrefix(assetsPath) || text.hasPrefix(appleDictionaryPrefix) { count += 1 }
        }
        return count == 0 ? .ready : .waiting(count: count)
    }
}

/// **Where a row's button sends the reader** (plan-setup-v2 WI-2, WI-5): the panes the three Look Up triggers and the
/// Service live in, as `x-apple.systempreferences` URLs.
///
/// The extension identifiers are the ones macOS 27 installs — read on disk 2026-10-22 in
/// `/System/Library/ExtensionKit/Extensions` (`KeyboardSettings.appex` → `com.apple.Keyboard-Settings.extension`,
/// `TrackpadExtension.appex` → `com.apple.Trackpad-Settings.extension`, `SpotlightPreferenceExtension.appex` →
/// `com.apple.Spotlight-Settings.extension`). **The tab anchor after `?` is undocumented**, so each link carries the one
/// Apple's own help uses and every open falls back to the pane's root when the system refuses it: a reader lands in the
/// right pane and can see the tabs, rather than on nothing.
public enum SettingsLink: String, Sendable {
    case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case keyboardShortcuts = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts"
    case trackpad = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
    case spotlight = "x-apple.systempreferences:com.apple.Spotlight-Settings.extension"

    public var url: URL? { URL(string: rawValue) }

    /// The pane without its anchor: what an open falls back to.
    public var paneRoot: URL? {
        guard let prefix = rawValue.split(separator: "?").first else { return nil }
        return URL(string: String(prefix))
    }
}

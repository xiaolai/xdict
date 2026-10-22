import Foundation

/// **An Apple dictionary Dictionary.app knows about that this Mac has not installed** (plan-setup-v2 WI-3; ADR-0011
/// decision 1, amended 2026-10-22): its name, which is its identity. **No size and no languages**, because neither
/// exists until macOS downloads it, and XDict does not download it (no MobileAsset API is public).
public struct AvailableBundle: Hashable, Sendable, Identifiable {
    /// The name macOS shows, without its `.dictionary` extension. It is the row's identity: the preference's own
    /// spelling (`asset:/<name>.dictionary`) differs only by that prefix and extension, and nothing shows it.
    public let name: String

    public var id: String { name }

    public init(name: String) {
        self.name = name
    }
}

/// **What Dictionary.app last knew was available on this Mac** (plan-setup-v2 WI-3): `com.apple.Dictionary` ▸
/// `last available dictionaries`, an array of strings that mixes installed paths with `asset:/…` names for the ones
/// macOS would download. Read-only — `CFPreferencesCopyAppValue`, and the app is not sandboxed — and documented
/// nowhere: a value that is not an array of strings is `.none`, which the sheet draws as "could not read", never as an
/// empty list that looks like nothing exists.
///
/// **The entry that separates this from a guess**: a name that matches an installed bundle — by its display name or its
/// folder's name — is already here and is not offered again.
public enum AvailableBundles {
    /// Dictionary.app's own domain and key.
    public static let domain = "com.apple.Dictionary"
    public static let key = "last available dictionaries"
    /// How the preference spells a dictionary macOS has not downloaded.
    public static let assetPrefix = "asset:/"
    public static let extensionName = ".dictionary"

    /// The whole set, less what is installed, sorted the way Finder sorts names.
    public static func discover(installed: [InstalledBundle]) -> [AvailableBundle]? {
        known(entries: read(), installed: installed)
    }

    /// **The matching rule, as a pure function** (plan-setup-v2 WI-3): the fixture drives the tests, never Apple's data.
    /// Nil is "the preference could not be read"; an empty array is "nothing is left to download".
    public static func known(entries: [String]?, installed: [InstalledBundle]) -> [AvailableBundle]? {
        guard let entries else { return nil }
        let taken = Set(installed.flatMap { [$0.displayName, $0.url.deletingPathExtension().lastPathComponent] }
            .map { $0.lowercased() })
        var seen = Set<String>()
        let found = entries.compactMap { entry -> AvailableBundle? in
            guard entry.hasPrefix(assetPrefix) else { return nil }  // an installed path: already on this Mac
            let file = String(entry.dropFirst(assetPrefix.count))
            guard file.hasSuffix(extensionName) else { return nil }
            let name = String(file.dropLast(extensionName.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !taken.contains(name.lowercased()), seen.insert(name.lowercased()).inserted else {
                return nil
            }
            return AvailableBundle(name: name)
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The preference, or nil when it is missing or not a list of strings.
    public static func read() -> [String]? {
        guard let raw = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else { return nil }
        guard let entries = raw as? [Any] else { return nil }
        let strings = entries.compactMap { $0 as? String }
        return strings.count == entries.count ? strings : nil
    }
}

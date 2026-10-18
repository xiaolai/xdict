import Foundation
import XDictContract

/// **An Apple dictionary installed on this Mac**, as the Add Apple Dictionaries… sheet lists it (ADR-0011 decisions 1
/// and 11): its names and version from `Info.plist`, its size, its languages when it declares them, and why XDict does
/// not convert it, if it does not. Read by the app, which parses nothing but the property list: the bundle's data is
/// read only by the service's converter.
public struct InstalledBundle: Hashable, Sendable, Identifiable {
    public let url: URL
    /// `CFBundleIdentifier`: what an imported copy is matched to (`AppleSourceRecord`).
    public let identifier: String
    /// `CFBundleDisplayName`, else `CFBundleName`, else the folder's name.
    public let displayName: String
    /// `CFBundleVersion`, else `CFBundleShortVersionString`.
    public let version: String?
    /// Bytes of its regular files.
    public let bytes: UInt64
    /// `DCSDictionaryLanguages`' first pair, as language codes (`en`, `zh-Hans`): what is searched, what explains.
    public let searchLanguage: String?
    public let explanationLanguage: String?
    /// Why XDict will not convert it; nil when it will try.
    public let refusal: AppleImportRefusal?

    public var id: String { identifier }

    public init(url: URL, identifier: String, displayName: String, version: String?, bytes: UInt64,
                searchLanguage: String?, explanationLanguage: String?, refusal: AppleImportRefusal?) {
        self.url = url
        self.identifier = identifier
        self.displayName = displayName
        self.version = version
        self.bytes = bytes
        self.searchLanguage = searchLanguage
        self.explanationLanguage = explanationLanguage
        self.refusal = refusal
    }
}

/// **Finds the Apple dictionaries installed on this Mac** (ADR-0011 decision 11): every `*.dictionary` under
/// `<root>/*/AssetData/`, the trusted location being the admission criterion; nothing elsewhere is offered.
public enum InstalledBundles {
    /// Where macOS installs the dictionaries Dictionary.app downloads.
    public static let systemRoot = URL(
        filePath: "/System/Library/AssetsV2/com_apple_MobileAsset_DictionaryServices_dictionary3macOS",
        directoryHint: .isDirectory)

    /// An `Info.plist` larger than this is not one: the installed bundles' are under 20 KB.
    public static let infoPlistLimit = 1 << 20

    /// Every bundle under `root`, by display name. One a reader could not have imported is listed with its refusal,
    /// never hidden. Two assets of one identifier (an update half-installed) give one: the later version.
    public static func discover(root: URL = systemRoot, bounds: SnapshotBounds = .production) -> [InstalledBundle] {
        var found: [String: InstalledBundle] = [:]
        for bundle in bundleURLs(under: root) {
            let read = Self.read(bundle, bounds: bounds)
            if let earlier = found[read.identifier], !isLater(read.version, than: earlier.version) { continue }
            found[read.identifier] = read
        }
        return found.values.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.identifier < $1.identifier : order == .orderedAscending
        }
    }

    /// The `*.dictionary` folders of `<root>/*/AssetData/`, never through a link.
    static func bundleURLs(under root: URL) -> [URL] {
        let fm = FileManager.default
        let assets = (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
        return assets.flatMap { asset -> [URL] in
            let data = root.appending(path: asset).appending(path: "AssetData", directoryHint: .isDirectory)
            guard isFolder(data) else { return [] }
            let names = (try? fm.contentsOfDirectory(atPath: data.path))?.sorted() ?? []
            return names.filter { $0.hasSuffix(".dictionary") }.map { data.appending(path: $0, directoryHint: .isDirectory) }
                .filter(isFolder)
        }
    }

    static func isFolder(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    static func isLater(_ version: String?, than other: String?) -> Bool {
        (version ?? "").compare(other ?? "", options: .numeric) == .orderedDescending
    }

    /// One bundle: its property list, then its files' count and size under the snapshot's bounds.
    static func read(_ bundle: URL, bounds: SnapshotBounds) -> InstalledBundle {
        let folderName = bundle.deletingPathExtension().lastPathComponent
        let info: [String: Any]
        switch plist(bundle) {
        case .success(let read): info = read
        case .failure(let refusal):
            return InstalledBundle(url: bundle, identifier: "\(folderName).dictionary", displayName: folderName,
                                   version: nil, bytes: 0, searchLanguage: nil, explanationLanguage: nil, refusal: refusal)
        }
        let identifier = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = [info["CFBundleDisplayName"], info["CFBundleName"]].lazy.compactMap { $0 as? String }
            .first { !$0.isEmpty } ?? folderName
        let version = (info["CFBundleVersion"] as? String) ?? (info["CFBundleShortVersionString"] as? String)
        let languages = (info["DCSDictionaryLanguages"] as? [Any])?.first as? [String: Any]
        var refusal = identifier == nil ? AppleImportRefusal.malformedInfoPlist(detail: "no CFBundleIdentifier")
            : Self.refusal(info)
        var bytes: UInt64 = 0
        do throws(AppleImportRefusal) {
            bytes = try Snapshot.scan(bundle, bounds: bounds).reduce(0) { $0 + UInt64($1.size) }
        } catch {
            refusal = refusal ?? error
        }
        return InstalledBundle(url: bundle, identifier: identifier ?? "\(folderName).dictionary", displayName: name,
                               version: version, bytes: bytes,
                               searchLanguage: code(languages?["DCSDictionaryIndexLanguage"] as? String),
                               explanationLanguage: code(languages?["DCSDictionaryDescriptionLanguage"] as? String),
                               refusal: refusal)
    }

    /// What the service would refuse, said before the reader asks (ADR-0011 decision 11): a format other than 3, no
    /// `KeyText.index` (the system "Apple Dictionary"). The rest is the converter's to find.
    static func refusal(_ info: [String: Any]) -> AppleImportRefusal? {
        // A `Bool` is not a version, though Foundation bridges `true` to 1 (as the converter reads it).
        let version = info["IDXDictionaryVersion"].flatMap { value -> Int? in
            CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() ? nil : value as? Int
        }
        guard version == 3 else { return .notVersion3(found: version) }
        guard let indexes = info["IDXDictionaryIndexes"] as? [Any] else {
            return .malformedInfoPlist(detail: "IDXDictionaryIndexes")
        }
        let paths = indexes.compactMap { ($0 as? [String: Any])?["IDXIndexPath"] as? String }
        return paths.contains("KeyText.index") ? nil : .noKeyTextIndex
    }

    static func plist(_ bundle: URL) -> Result<[String: Any], AppleImportRefusal> {
        let url = bundle.appending(path: "Contents/Info.plist")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return .failure(errno == ELOOP ? .symbolicLink(path: "Contents/Info.plist")
                : .malformedInfoPlist(detail: "unreadable: \(errno)"))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: infoPlistLimit + 1), data.count <= infoPlistLimit,
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = parsed as? [String: Any] else {
            return .failure(.malformedInfoPlist(detail: "not a dictionary property list"))
        }
        return .success(info)
    }

    /// `en_US` → `en`; Chinese keeps its script (`zh_CN` → `zh-Hans`, `zh_TW` → `zh-Hant`), as the library's codes do.
    static func code(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier else { return nil }
        guard code == "zh" else { return code }
        let script = language.script ?? Locale.Language(identifier: language.maximalIdentifier).script
        return script.map { "zh-\($0.identifier)" } ?? code
    }
}

import Foundation
import XDictAppleSource

/// An installed bundle as the update check compares it: its source revision now, nil when it could not be read.
public struct InstalledSource: Hashable, Sendable {
    public let sourceRevision: String?

    public init(sourceRevision: String?) {
        self.sourceRevision = sourceRevision
    }
}

/// **What became of an Apple dictionary's bundle** (ADR-0011 decisions 7 and 9), compared at launch and when Settings
/// opens. Kinds, never sentences: the view layer words them.
public enum AppleStatus: Hashable, Sendable {
    /// The bundle is as it was converted, by the converter this XDict has.
    case current
    /// Apple changed what the converter reads, or XDict changed the converter: Convert Again is offered.
    case updated
    /// The bundle is gone from this Mac; the converted copy still reads.
    case removed

    /// The rule: no bundle of the identifier is `removed`; a source revision or a converter revision other than the
    /// recorded one is `updated` (a change only to `*.lproj` or the signature never reaches the revision); a bundle that
    /// could not be read now offers nothing, since converting it would fail.
    public static func of(_ record: AppleSourceRecord, installed: InstalledSource?, converter: UInt32) -> AppleStatus {
        guard let installed else { return .removed }
        guard let revision = installed.sourceRevision else { return .current }
        return revision != record.sourceRevision || converter != record.converterRevision ? .updated : .current
    }
}

extension InstalledSource {
    /// The installed bundles an imported Apple dictionary names, each hashed now by the manifest the service stamps
    /// (`Manifest.revision(of:)`): read off the main actor, since a bundle is up to 123 MB.
    public static func current(of bundles: [InstalledBundle], wanted: Set<String>) async -> [String: InstalledSource] {
        let chosen = bundles.filter { wanted.contains($0.identifier) }
        return await Task.detached(priority: .utility) {
            var found: [String: InstalledSource] = [:]
            for bundle in chosen {
                found[bundle.identifier] = InstalledSource(
                    sourceRevision: bundle.refusal == nil ? try? Manifest.revision(of: bundle.url) : nil)
            }
            return found
        }.value
    }
}

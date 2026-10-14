import Foundation

/// **Where a stored file is now** (ADR-0009 decision 1; L5): its security-scoped bookmark first, which follows the file
/// when it or a folder above it moves, then the path it was last found at. **Only a canonical path is ever handed on**
/// (no link anywhere in it): a link put in a file's place, or in a folder's, is refused rather than followed, so what
/// the service is sent is the file that was chosen or nothing (ADR-0009 refutation row 7).
public struct FileLocator: Sendable {
    public enum Resolution: Hashable, Sendable {
        /// Found at `url`, its canonical path; `renewed` when the stored location should be replaced by it (the file
        /// moved, or its bookmark went stale).
        case found(url: URL, renewed: StoredLocation?)
        case missing
        /// Something is at the place, and it is, or goes through, a link: refused, never followed.
        case notCanonical
    }

    /// Whether a bookmark is asked at all: off only for the E2E positive control, where a moved file must go missing.
    public let relinking: Bool

    public init(relinking: Bool) {
        self.relinking = relinking
    }

    /// A location to keep for `url`: its canonical path, and a security-scoped bookmark to it.
    public static func store(_ url: URL) throws -> StoredLocation {
        guard case .found(let canonical) = check(url) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let bookmark = try canonical.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)
        return StoredLocation(bookmark: bookmark, path: canonical.path)
    }

    public func resolve(_ stored: StoredLocation) -> Resolution {
        if relinking {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: stored.bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                switch Self.check(url) {
                case .found(let canonical):
                    guard stale || canonical.path != stored.path else { return .found(url: canonical, renewed: nil) }
                    let renewed = (try? Self.store(canonical)) ?? StoredLocation(bookmark: stored.bookmark,
                                                                                 path: canonical.path)
                    return .found(url: canonical, renewed: renewed)
                case .notCanonical:
                    return .notCanonical
                case .missing:
                    break
                }
            }
        }
        switch Self.check(URL(fileURLWithPath: stored.path)) {
        case .found(let canonical): return .found(url: canonical, renewed: nil)
        case .notCanonical: return .notCanonical
        case .missing: return .missing
        }
    }

    /// Whether canonical `url` lies inside canonical `folder` (and is not the folder itself).
    public static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return url.path.hasPrefix(base) && url.path.count > base.count
    }

    enum Check: Hashable {
        case found(URL)
        case missing
        case notCanonical
    }

    /// `realpath(3)` of `url`: nothing there is missing; a path that is not its own canonical form goes through a link.
    /// (Never `standardizedFileURL`: it strips `/private` from `/private/var`, turning a canonical path into a link.)
    static func check(_ url: URL) -> Check {
        let path = url.path
        guard let resolved = realpath(path, nil) else { return .missing }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        return canonical == path ? .found(URL(fileURLWithPath: canonical)) : .notCanonical
    }

    /// The canonical form of `url`, links resolved, or nil if nothing is there: for what the reader chose, which may
    /// itself be reached through a link (`/tmp`, an alias of a folder).
    public static func canonical(_ url: URL) -> URL? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

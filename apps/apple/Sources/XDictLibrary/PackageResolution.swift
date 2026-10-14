import Foundation
import Synchronization
import XDictContract

/// **Where a stored dictionary's files are now, and whether they may be read there** (ADR-0009 decision 1; L5): each file
/// found where it is now (`FileLocator`: its bookmark first, unless relinking is off; a link is never followed), and all
/// of them held inside one folder — the folder the reader chose while the MDX is still in it, or else the MDX's own
/// folder, when the chosen one cannot be found or the dictionary's own folder was moved out of it. One rule, for the
/// library's resolution and for a relink while the dictionary is open (`LivePackage`), so neither follows a file out of
/// its folder (the security review of 2026-10-15).
struct PackageResolution: Sendable {
    struct Found {
        /// Each file's canonical URL, in the order of `files`.
        let urls: [URL]
        /// The folder every file was found inside.
        let folder: URL
        /// The files and the folder the reader chose, with the locations that moved renewed.
        let files: [StoredFile]
        let root: StoredLocation
        /// Whether any location was renewed.
        let changed: Bool
    }

    let locator: FileLocator

    func resolve(_ stored: [StoredFile], root storedRoot: StoredLocation) -> Result<Found, Unresolved> {
        var files = stored, root = storedRoot, urls: [URL] = [], changed = false
        for (position, file) in files.enumerated() {
            switch locator.resolve(file.location) {
            case .found(let url, let renewed):
                urls.append(url)
                if let renewed {
                    files[position].location = renewed
                    changed = true
                }
            case .missing:
                return .failure(Unresolved(phase: .missing(fileName: file.fileName)))
            case .notCanonical:
                return .failure(Unresolved(phase: .outsideItsFolder(fileName: file.fileName)))
            }
        }
        // A package without its MDX holds nowhere: refused, never read without a folder to hold it to.
        guard let mdx = zip(files, urls).first(where: { $0.0.role == .mdx })?.1 else {
            return .failure(Unresolved(phase: .missing(fileName: "")))
        }
        let folder: URL
        switch locator.resolve(root) {
        case .found(let chosen, let renewed):
            folder = FileLocator.isInside(mdx, chosen) ? chosen : mdx.deletingLastPathComponent()
            if let renewed {
                root = renewed
                changed = true
            }
        case .missing, .notCanonical:
            folder = mdx.deletingLastPathComponent()
        }
        if let outside = zip(files, urls).first(where: { !FileLocator.isInside($0.1, folder) }) {
            return .failure(Unresolved(phase: .outsideItsFolder(fileName: outside.0.fileName)))
        }
        return .success(Found(urls: urls, folder: folder, files: files, root: root, changed: changed))
    }
}

/// **A dictionary's files for the service's client while it is open** (`PackageFile.locate`, asked before every token and
/// every open, including the client's own open after a restart): the canonical paths of its resolution. When one answers
/// ENOENT (ADR-0009 decision 1: the app re-resolves before it sends `missing`), the file's bookmark is asked, and its new
/// place taken only inside the folder the package was held to; otherwise the whole package is resolved again by the same
/// rule, and taken only if it holds. Either way a relink never follows a file out of its folder, nor through a link: a
/// path a link has come into answers ELOOP, not ENOENT, and stays as it is for the client to refuse.
final class LivePackage: Sendable {
    private struct Now {
        var urls: [URL]
        var folder: URL
    }

    private let files: [StoredFile]
    private let root: StoredLocation
    private let rule: PackageResolution
    private let now: Mutex<Now>

    init(_ found: PackageResolution.Found, rule: PackageResolution) {
        files = found.files
        root = found.root
        self.rule = rule
        now = Mutex(Now(urls: found.urls, folder: found.folder))
    }

    /// The file at `position` of the package's files.
    func current(_ position: Int) -> URL {
        now.withLock { now in
            let url = now.urls[position]
            var info = stat()
            if fstatat(AT_FDCWD, url.path, &info, AT_SYMLINK_NOFOLLOW_ANY) == 0 || errno != ENOENT { return url }
            if case .found(let moved, _) = rule.locator.resolve(files[position].location),
               FileLocator.isInside(moved, now.folder) {
                now.urls[position] = moved
                return moved
            }
            if case .success(let found) = rule.resolve(files, root: root) {
                now = Now(urls: found.urls, folder: found.folder)
            }
            return now.urls[position]
        }
    }
}

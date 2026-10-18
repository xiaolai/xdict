import Foundation

/// **The converter's revision, as the app compares it** (ADR-0011 decision 7): bumped with any change to the bytes the
/// converter writes, so an imported copy made by an older converter is offered Convert Again. The converter owns the
/// number (`AppleImport.converterRevision`, linked by the service alone); `AppleSourceSharingTests` holds this one to it.
public enum AppleConverter {
    public static let revision: UInt32 = 1
}

/// **The launch sweep** (ADR-0011 decision 9): publication is staging → output folder → library import → library
/// save, and a crash may stop it at any step. At launch every staging folder goes (a copy no conversion will take), and
/// every output folder no library entry names that is older than `maxAge`. A removed dictionary's folder is kept until
/// then, so Undo restores one that still reads, even after Apple removed the bundle; a day lets a conversion that is
/// published but not yet imported by another launch of the app survive it.
public enum AppleImportSweep {
    public static let maxAge: TimeInterval = 24 * 60 * 60

    public struct Report: Equatable, Sendable {
        /// Staging folders removed, by name.
        public var staging: [String] = []
        /// Output folders removed.
        public var outputs: [UUID] = []
        /// Output folders no entry names, kept because they are younger than `maxAge`.
        public var young: [UUID] = []

        public init() {}
    }

    /// Sweeps `root` (`AppleImports/`): `referenced` are the conversions the library names.
    @discardableResult
    public static func sweep(_ root: URL, referenced: Set<UUID>, now: Date = Date(), maxAge: TimeInterval = maxAge)
        -> Report {
        var report = Report()
        let fm = FileManager.default
        let staging = SharedContainer.staging(in: root)
        for name in ((try? fm.contentsOfDirectory(atPath: staging.path)) ?? []).sorted() {
            // `removeItem` on a link removes the link, never what it points to.
            if (try? fm.removeItem(at: staging.appending(path: name))) != nil { report.staging.append(name) }
        }
        for name in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() {
            guard let conversion = UUID(uuidString: name), conversion.uuidString == name,
                  !referenced.contains(conversion) else { continue }
            let url = root.appending(path: name)
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(modified) > maxAge else {
                report.young.append(conversion)
                continue
            }
            if (try? fm.removeItem(at: url)) != nil { report.outputs.append(conversion) }
        }
        return report
    }
}

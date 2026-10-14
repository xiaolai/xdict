import Foundation
import XDictContract

/// Something about one dictionary the reader should know, kept with it (`LibraryEntry.notes`).
public enum EntryNote: Codable, Hashable, Sendable {
    /// A volume the numbering says exists and the folder does not hold (L2): its resources will be missing.
    case missingVolume(fileName: String)
    /// A file beside the dictionary that is a link to somewhere outside the folder the reader chose: never read.
    case outsideChosenFolder(fileName: String)
    /// More files beside the dictionary than one package holds (`Limits.maxPackageFiles`): these many were left out.
    case sidecarsOmitted(count: Int)
    /// A volume the import could not read; its resources will be reported missing.
    case volumeUnreadable(fileName: String, reason: ImportRefusal)
}

/// What the reader chose that gave no dictionary, said rather than skipped.
public enum FinderProblem: Hashable, Sendable {
    case notADictionaryFile(fileName: String)
    case noDictionaryIn(folderName: String)
    /// Resource volumes with no MDX of their name beside them.
    case volumesWithoutDictionary(fileNames: [String])
    /// An MDX that is a link to somewhere outside the folder the reader chose.
    case outsideChosenFolder(fileName: String)
    case unreadable(fileName: String)
}

/// One dictionary as the core expects it (ADR-0007 decision 4), found on disk: every location canonical (no link left
/// in it) and inside the folder the reader chose.
public struct FoundPackage: Hashable, Sendable {
    public struct Volume: Hashable, Sendable {
        public let url: URL
        /// The name as the folder spells it, which the reader recognises.
        public let fileName: String
    }

    public struct Sidecar: Hashable, Sendable {
        public let url: URL
        /// Its name in the package, which the core matches against the resource paths entries ask for.
        public let pathInPackage: String
    }

    /// The folder the reader chose, or the folder of the file they chose.
    public let root: URL
    public let mdx: URL
    /// In search order: `x.mdd`, `x.1.mdd`, `x.2.mdd`…
    public let volumes: [Volume]
    public let sidecars: [Sidecar]
    public let notes: [EntryNote]
}

public struct FinderResult: Sendable {
    public let packages: [FoundPackage]
    public let problems: [FinderProblem]
}

/// **Finds the dictionaries in what the reader chose** (plan-macos-v1 WI-5, L2), as `entries_corpus.rs` and
/// `index_bench` assemble them: each MDX with the volumes of its stem (`x.mdd`, `x.1.mdd`, `x.2.mdd`…) in number order,
/// a gap in the numbers named, and the other files of its folder as sidecars — those named for another MDX of the same
/// folder (`b.css` beside `a.mdx` and `b.mdx`) left to it, the rest shared. A chosen folder is searched `maxDepth` levels
/// down; a chosen file brings its folder's companions.
///
/// **Nothing is taken from outside what the reader chose** (ADR-0009 refutation row 7): every file is followed to its
/// canonical path, and one that lands outside the chosen folder is left out and named — the package refused if it is the
/// MDX. Links are never descended into. Only names, links and kinds are read here, never a dictionary's bytes.
public enum PackageFinder {
    /// How far below a chosen folder dictionaries are looked for: `corpus/name/x.mdx` and one more.
    public static let maxDepth = 3

    public static func find(in chosen: [URL]) -> FinderResult {
        var search = Search()
        for url in chosen {
            let name = url.lastPathComponent
            guard let canonical = FileLocator.canonical(url) else {
                search.problems.append(.unreadable(fileName: name))
                continue
            }
            var isFolder: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isFolder)
            if isFolder.boolValue {
                let before = search.dictionariesSeen
                search.walk(canonical, root: canonical, depth: 0)
                if search.dictionariesSeen == before { search.problems.append(.noDictionaryIn(folderName: name)) }
            } else {
                search.chosenFile(canonical, as: name)
            }
        }
        return FinderResult(packages: search.packages.sorted { $0.mdx.path < $1.mdx.path }, problems: search.problems)
    }

    // MARK: - Names

    enum Kind { case mdx, mdd, other }

    static func kind(_ name: String) -> Kind {
        switch (name as NSString).pathExtension.lowercased() {
        case "mdx": .mdx
        case "mdd": .mdd
        default: .other
        }
    }

    static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    /// A volume's number for an MDX stem: `x.mdd` is 0, `x.N.mdd` is N; nil for another stem's.
    static func volumeNumber(_ name: String, of stem: String) -> Int? {
        let volume = Self.stem(name).lowercased(), stem = stem.lowercased()
        if volume == stem { return 0 }
        guard volume.hasPrefix(stem + "."), let number = Int(volume.dropFirst(stem.count + 1)), number > 0 else {
            return nil
        }
        return number
    }

    static func volumeName(_ number: Int, of stem: String) -> String {
        number == 0 ? "\(stem).mdd" : "\(stem).\(number).mdd"
    }

    /// Whether a file beside several MDX belongs to `stem`'s: it does unless it is named for another (the longest stem
    /// it starts with, followed by a dot, owns it); a file named for none is shared.
    static func belongs(_ name: String, to stem: String, among stems: [String]) -> Bool {
        let lower = name.lowercased()
        let owners = stems.filter { lower.hasPrefix($0.lowercased() + ".") }
        guard let owner = owners.max(by: { $0.count < $1.count }) else { return true }
        return owner.lowercased() == stem.lowercased()
    }

    /// Stylesheets and scripts first, then fonts, then the rest: what an entry needs to look right is kept first when a
    /// package has more files than the contract takes.
    static func priority(_ name: String) -> Int {
        switch (name as NSString).pathExtension.lowercased() {
        case "css": 0
        case "js": 1
        case "ttf", "otf", "woff", "woff2": 2
        default: 3
        }
    }

    // MARK: - The search

    /// A file of a folder: its name there, and its canonical location.
    struct Listed {
        let name: String
        let url: URL
    }

    struct Search {
        var packages: [FoundPackage] = []
        var problems: [FinderProblem] = []
        var seen = Set<String>()
        /// MDX files met, duplicates included: a folder that held any was not empty of dictionaries.
        var dictionariesSeen = 0

        mutating func chosenFile(_ file: URL, as name: String) {
            let folder = file.deletingLastPathComponent()
            switch PackageFinder.kind(file.lastPathComponent) {
            case .mdx:
                dictionariesSeen += 1
                let (inside, outside) = Self.list(folder, root: folder)
                add(package(for: Listed(name: file.lastPathComponent, url: file), in: inside, outside: outside,
                            root: folder))
            case .mdd:
                let (inside, outside) = Self.list(folder, root: folder)
                let owner = inside.first { PackageFinder.kind($0.name) == .mdx
                    && PackageFinder.volumeNumber(file.lastPathComponent, of: PackageFinder.stem($0.name)) != nil }
                guard let owner else {
                    problems.append(.volumesWithoutDictionary(fileNames: [name]))
                    return
                }
                dictionariesSeen += 1
                add(package(for: owner, in: inside, outside: outside, root: folder))
            case .other:
                problems.append(.notADictionaryFile(fileName: name))
            }
        }

        mutating func walk(_ folder: URL, root: URL, depth: Int) {
            let (inside, outside) = Self.list(folder, root: root)
            let mdx = inside.filter { PackageFinder.kind($0.name) == .mdx }
            for escaped in outside where PackageFinder.kind(escaped) == .mdx {
                problems.append(.outsideChosenFolder(fileName: escaped))
            }
            dictionariesSeen += mdx.count
            for file in mdx { add(package(for: file, in: inside, outside: outside, root: root)) }
            let stems = mdx.map { PackageFinder.stem($0.name) }
            let strays = inside.filter { file in
                PackageFinder.kind(file.name) == .mdd && !stems.contains { PackageFinder.volumeNumber(file.name, of: $0) != nil }
            }
            if !strays.isEmpty { problems.append(.volumesWithoutDictionary(fileNames: strays.map(\.name).sorted())) }
            guard depth < PackageFinder.maxDepth else { return }
            for sub in Self.subfolders(folder) { walk(sub, root: root, depth: depth + 1) }
        }

        mutating func add(_ package: FoundPackage) {
            guard seen.insert(package.mdx.path).inserted else { return }
            packages.append(package)
        }

        /// The package of `mdx` among its folder's files.
        func package(for mdx: Listed, in inside: [Listed], outside: [String], root: URL) -> FoundPackage {
            let stem = PackageFinder.stem(mdx.name)
            let stems = inside.filter { PackageFinder.kind($0.name) == .mdx }.map { PackageFinder.stem($0.name) }
            let volumes = inside.compactMap { file -> (Int, Listed)? in
                guard PackageFinder.kind(file.name) == .mdd, let number = PackageFinder.volumeNumber(file.name, of: stem)
                else { return nil }
                return (number, file)
            }.sorted { $0.0 < $1.0 }
            let escapedVolumes = outside.compactMap { name in
                PackageFinder.kind(name) == .mdd ? PackageFinder.volumeNumber(name, of: stem) : nil
            }
            var notes: [EntryNote] = []
            let numbers = Set(volumes.map(\.0) + escapedVolumes)
            if let last = numbers.max() {
                for number in 0...last where !numbers.contains(number) {
                    notes.append(.missingVolume(fileName: PackageFinder.volumeName(number, of: stem)))
                }
            }
            for escaped in outside where PackageFinder.kind(escaped) != .mdx {
                let mine = PackageFinder.kind(escaped) == .mdd ? PackageFinder.volumeNumber(escaped, of: stem) != nil
                    : PackageFinder.belongs(escaped, to: stem, among: stems)
                if mine { notes.append(.outsideChosenFolder(fileName: escaped)) }
            }
            var sidecars = inside.filter { file in
                PackageFinder.kind(file.name) == .other && PackageFinder.belongs(file.name, to: stem, among: stems)
            }.sorted { (PackageFinder.priority($0.name), $0.name) < (PackageFinder.priority($1.name), $1.name) }
            let room = max(0, Limits.maxPackageFiles - 1 - volumes.count)
            if sidecars.count > room {
                notes.append(.sidecarsOmitted(count: sidecars.count - room))
                sidecars = Array(sidecars.prefix(room))
            }
            return FoundPackage(root: root, mdx: mdx.url,
                                volumes: volumes.map { FoundPackage.Volume(url: $0.1.url, fileName: $0.1.name) },
                                sidecars: sidecars.map { FoundPackage.Sidecar(url: $0.url, pathInPackage: $0.name) },
                                notes: notes)
        }

        /// A folder's visible regular files, each followed to its canonical location: those inside `root`, and the names
        /// of those whose links lead out of it. Folders, and links to folders, are not files.
        static func list(_ folder: URL, root: URL) -> (inside: [Listed], outside: [String]) {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles])) ?? []
            var inside: [Listed] = [], outside: [String] = []
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let canonical = FileLocator.canonical(item) else { continue }
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isFolder), !isFolder.boolValue
                else { continue }
                if FileLocator.isInside(canonical, root) {
                    inside.append(Listed(name: item.lastPathComponent, url: canonical))
                } else {
                    outside.append(item.lastPathComponent)
                }
            }
            return (inside, outside)
        }

        /// A folder's visible subfolders, never through a link.
        static func subfolders(_ folder: URL) -> [URL] {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
            return items.filter { item in
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { folder.appending(path: $0.lastPathComponent) }
        }
    }
}

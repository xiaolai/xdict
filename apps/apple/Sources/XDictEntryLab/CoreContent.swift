import Foundation
import XDictCore
import XDictEntryView

/// Why the lab stopped: said once, on standard error, with exit status 2 — a lab that could not do what it was asked
/// must never write a report that reads like a run.
struct LabFailure: Error, CustomStringConvertible {
    let description: String
}

/// **The core, opened in this process** — the lab's whole reason to exist. It is a development instrument: XDict.app
/// never links the core (`ModuleBoundaryTests`, `Tools/build-bundle.sh`); its service does (WI-3).
final class LabCore: @unchecked Sendable {
    let core: Core

    init(cache: URL) throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        core = try Core(config: Config(dataDir: cache.path, cacheDir: cache.path, clientProtocol: versions().protocol,
                                       entropy: Data()))
    }

    /// A folder as a package, as `entries_corpus` reads one: its MDX, its MDD volumes in order (`X.mdd`, `X.1.mdd`, …),
    /// every other file a sidecar.
    static func package(_ folder: URL) throws -> Package {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let ext = { (url: URL) in url.pathExtension.lowercased() }
        guard let mdx = files.first(where: { ext($0) == "mdx" }) else {
            throw LabFailure(description: "no .mdx in \(folder.path)")
        }
        func volume(_ url: URL) -> Int {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let dot = stem.lastIndex(of: "."), let n = Int(stem[stem.index(after: dot)...]) else { return 0 }
            return n + 1
        }
        let mdd = files.filter { ext($0) == "mdd" }.sorted { volume($0) < volume($1) }
        let sidecars = files.filter { ext($0) != "mdx" && ext($0) != "mdd" }
        return Package(mdx: .path(path: mdx.path), mdd: mdd.map { .path(path: $0.path) },
                       sidecars: sidecars.map { .path(path: $0.path) })
    }

    /// Imports (when needed) and opens the dictionary in `folder`.
    func open(_ folder: URL) throws -> CoreContent {
        let package = try Self.package(folder)
        var opened = try core.open(package: package)
        if case .needsImport = opened {
            _ = try core.import(package: package, progress: nil)
            opened = try core.open(package: package)
        }
        guard case .ready(let dict, let edition, let info) = opened else {
            throw LabFailure(description: "\(folder.lastPathComponent) did not open after import: \(opened)")
        }
        let binding = EntryBinding(dictionary: "lab." + folder.lastPathComponent, edition: edition, handle: dict)
        return CoreContent(core: core, binding: binding, title: info.title, folder: folder)
    }
}

/// `EntryContent` over the core in this process, under the contract's render context (`xdict://d/`, 16 MiB).
final class CoreContent: EntryContent, @unchecked Sendable {
    let core: Core
    let binding: EntryBinding
    let title: String
    let folder: URL
    let view = View(baseUrl: EntryRoutes.base, maxBodyBytes: UInt64(EntryResourceServer.maxRenderedBytes))

    init(core: Core, binding: EntryBinding, title: String, folder: URL) {
        self.core = core
        self.binding = binding
        self.title = title
        self.folder = folder
    }

    private func reference(_ reference: EntryReference) -> EntryRef {
        EntryRef(edition: binding.edition, key: reference.key, occurrence: reference.occurrence)
    }

    func entry(_ reference: EntryReference) async throws -> EntryDocument {
        let ref = self.reference(reference)
        let (core, dict, view) = (self.core, binding.handle, self.view)
        let entry = try await Task.detached { try core.entry(dict: dict, entry: ref, view: view) }.value
        return EntryDocument(html: Data(entry.html.utf8), policy: entry.csp)
    }

    func resource(_ path: String) async throws -> EntryResource {
        let (core, dict, view) = (self.core, binding.handle, self.view)
        let answer = try await Task.detached { try core.resource(dict: dict, path: path, view: view) }.value
        switch answer {
        case .found(_, let mime, let bytes): return .found(mime: mime, bytes: bytes)
        case .missing: return .missing
        }
    }

    func link(_ url: String, origin: EntryLinkOrigin) async throws -> EntryLink {
        let (core, dict, view) = (self.core, binding.handle, self.view)
        let from: LinkOrigin = switch origin {
        case .entry(let reference): .entry(entry: self.reference(reference))
        case .resource(let path): .resource(path: path)
        }
        let link = try await Task.detached { try core.link(dict: dict, url: url, origin: from, view: view) }.value
        switch link {
        case .lookup(let query, let anchor): return .lookup(query: query, anchor: anchor)
        case .resource(let path): return .resource(path: path)
        case .sound(let path): return .sound(path: path)
        case .speak(let text): return .speak(text: text)
        case .anchor(let name): return .anchor(name: name)
        case .blocked(.remote(let url)): return .blocked(.remote(url: url))
        case .blocked(.script): return .blocked(.script)
        case .blocked(.unknownScheme(let scheme)): return .blocked(.unknownScheme(scheme))
        }
    }
}

/// `EntryContent` that holds back the answer to resources whose path contains `held` until `release()`: the binding
/// test's late request (ADR-0009 refutation, item 13). Everything it answered is logged with the package it came from.
final class HeldContent: EntryContent, @unchecked Sendable {
    let inner: CoreContent
    let held: String?
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var log: [[String: String]] = []

    init(_ inner: CoreContent, holding held: String?) {
        self.inner = inner
        self.held = held
    }

    var binding: EntryBinding { inner.binding }
    var holding: Int { lock.withLock { waiting.count } }

    func release() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiting.removeAll() }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    private func note(_ entry: [String: String]) {
        lock.withLock { log.append(entry) }
    }

    func entry(_ reference: EntryReference) async throws -> EntryDocument {
        try await inner.entry(reference)
    }

    func resource(_ path: String) async throws -> EntryResource {
        if let held, path.contains(held) {
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> Bool in
                    if released { return true }
                    waiting.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }
        let answer = try await inner.resource(path)
        var text = ""
        if case .found(_, let bytes) = answer { text = String(decoding: bytes.prefix(200), as: UTF8.self) }
        note(["path": path, "package": inner.folder.lastPathComponent, "answer": text,
              "at": String(Date().timeIntervalSince1970)])
        return answer
    }

    func link(_ url: String, origin: EntryLinkOrigin) async throws -> EntryLink {
        try await inner.link(url, origin: origin)
    }
}

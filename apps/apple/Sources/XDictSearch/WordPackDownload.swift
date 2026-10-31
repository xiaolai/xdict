import CryptoKit
import Foundation

/// **The pinned sources the word pack is built from** (plan-local-word-pack WI-6): the manifest that ships in the app,
/// read here as the one list of what to fetch, what each is called and what it must hash to. The six downloads are the
/// five sources and the two notice files the OEWN licence needs beside it; a Kaikki source carries no URL and is not
/// fetched, because it is only ever read through a receipt.
///
/// The manifest's own bytes travel to the container with the sources, so the service builds against the very manifest
/// the app checked each file against — never against a second copy that could have drifted.
public struct WordPackSources: Equatable, Sendable {
    /// One pinned download.
    public struct Item: Equatable, Sendable {
        /// The plain file name in the container's `sources` folder.
        public let file: String
        /// Where its bytes come from.
        public let url: URL
        /// The SHA-256 it must have.
        public let sha256: String
        /// The size it must have.
        public let bytes: UInt64
    }

    public let items: [Item]

    /// The name the manifest is copied under, beside the sources.
    public static let manifestName = "word_lexicon_sources.json"

    public init(items: [Item]) {
        self.items = items
    }

    /// The manifest, parsed: every pinned download it names, in the order it names them. `nil` when the bytes are not a
    /// manifest this release reads, or name a download twice.
    public init?(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == "xdict-word-lexicon-sources",
              root["version"] as? Int == 2,
              let sources = root["sources"] as? [[String: Any]], !sources.isEmpty
        else { return nil }
        var items: [Item] = []
        for source in sources {
            // A Kaikki source is read only through a receipt and carries no download; every other one must be whole.
            if source["provider"] as? String == "kaikki" { continue }
            guard let item = Self.item(source) else { return nil }
            items.append(item)
            if let notices = source["notice_files"] {
                guard let list = notices as? [[String: Any]] else { return nil }
                for notice in list {
                    guard let held = Self.item(notice) else { return nil }
                    items.append(held)
                }
            }
        }
        guard !items.isEmpty, Set(items.map(\.file)).count == items.count else { return nil }
        self.items = items
    }

    /// One pinned download, or `nil` when the entry is not whole: the manifest is checked as a whole, never skimmed.
    private static func item(_ entry: [String: Any]) -> Item? {
        guard let file = entry["file"] as? String, plainFile(file),
              let text = entry["url"] as? String,
              let url = URL(string: text), url.scheme == "https",
              let sha256 = entry["sha256"] as? String, sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let bytes = entry["bytes"] as? Int, bytes > 0
        else { return nil }
        return Item(file: file, url: url, sha256: sha256, bytes: UInt64(bytes))
    }

    /// **A plain file name**: no separator and no leading dot, so a name can never reach outside the sources folder —
    /// which matters twice, since the failure path deletes by that name.
    static func plainFile(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\") else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    /// Every file's size together: what a progress bar counts against.
    public var totalBytes: UInt64 {
        items.reduce(0) { $0 &+ $1.bytes }
    }
}

/// Where a pinned file's bytes come from: the network in the app, a fake in the tests.
public protocol WordPackTransfer: Sendable {
    /// Writes `url`'s bytes to `destination`, reporting the bytes so far, and throws `CancellationError` when the
    /// task is cancelled. A response that is not a success is a failure, never a file.
    func fetch(_ url: URL, to destination: URL, written: @escaping @Sendable (Int64) -> Void) async throws
}

/// The network, through `URLSession`, streaming each file to a temporary and moving it into place.
public struct URLSessionTransfer: WordPackTransfer {
    public init(session: URLSession = .shared) {
        self.session = session
    }

    private let session: URLSession

    public func fetch(_ url: URL, to destination: URL, written: @escaping @Sendable (Int64) -> Void) async throws {
        let reporter = Reporter(written: written)
        // **The async call's first value is the downloaded file itself** (2026-10-31): a task-specific delegate receives
        // no download callbacks on macOS 27, so waiting for `didFinishDownloadingTo` left `destination` unwritten while
        // this call reported success. The delegate is kept for progress only; the file is moved into place below.
        let (temporary, response) = try await session.download(for: URLRequest(url: url), delegate: reporter)
        if let error = reporter.recorded() {
            Self.discard(temporary)
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            Self.discard(temporary)
            throw WordPackDownload.Failure.transport(file: url.lastPathComponent, detail: "HTTP \(status)")
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.move(temporary, to: destination)
        } catch {
            Self.discard(temporary)
            throw WordPackDownload.Failure.transport(file: url.lastPathComponent, detail: "\(error)")
        }
    }

    /// **A temporary file this code will not keep is deleted here**: it is the system's, never the caller's, so a
    /// failed status or a failed move must not leave it behind. The failure that caused the discard is what is thrown.
    private static func discard(_ temporary: URL) {
        try? FileManager.default.removeItem(at: temporary)
    }

    /// The downloaded file into its place: a rename where the destination is new, and `replaceItemAt` — the atomic
    /// replacement — where an earlier copy is there to be replaced.
    private static func move(_ temporary: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}

/// Reports a download's bytes as they land. `URLSession` holds its delegate weakly, so the call keeps it alive.
///
/// **The file is never moved here** (2026-10-31): Apple documents `download(for:delegate:)`'s delegate parameter as
/// "reserved for future use", and on macOS 27 this task-specific delegate receives no download callbacks at all — so a
/// transport that waited for `didFinishDownloadingTo` to write the file reported success with nothing written.
/// `URLSessionTransfer.fetch` moves the temporary file the async call returns; this delegate is for progress only.
private final class Reporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    init(written: @escaping @Sendable (Int64) -> Void) {
        self.written = written
    }

    private let written: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var failure: (any Error)?

    /// **`didWriteData` is a `URLSessionDownloadDelegate` requirement**, not a task-delegate one: conforming to the
    /// task delegate left every download silent.
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        written(totalBytesWritten)
    }

    /// **A stub, because Swift's conformance requires it — never called by the async download** (see the type's note).
    /// Were it ever called, the system deletes `location` when this returns, so the file `fetch` moves is the async
    /// call's returned URL, never this one.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        if let error, failure == nil {
            failure = error
        }
    }

    /// What went wrong, once the call has returned.
    func recorded() -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}

/// **Fetches the pinned files and proves each is the one the manifest pins** (plan-local-word-pack WI-6): the size and
/// the SHA-256 are checked against the manifest that ships in the app — never against a hash fetched beside the file,
/// which a man in the middle could choose. **A failure leaves nothing behind**: every file this run wrote is removed,
/// so the folder never holds half a pack for a build to read.
public struct WordPackDownload: Sendable {
    /// Why a download did not finish, each naming the file the reader has to look at.
    public enum Failure: Error, Equatable, Sendable {
        /// The fetch itself failed: the transport, or a response that was not a success.
        case transport(file: String, detail: String)
        /// The file arrived at the wrong size.
        case sizeMismatch(file: String, expected: UInt64, found: UInt64)
        /// The file's bytes are not the ones the manifest pins, and both hashes are shown.
        case hashMismatch(file: String, expected: String, found: String)
    }

    public init(sources: WordPackSources, transfer: any WordPackTransfer = URLSessionTransfer()) {
        self.sources = sources
        self.transfer = transfer
    }

    public let sources: WordPackSources
    private let transfer: any WordPackTransfer

    /// Downloads every file into `folder`, verifying each. `progress` hears the file being fetched (1-based), the
    /// bytes done of all and the total.
    public func fetch(into folder: URL, progress: @escaping @Sendable (Int, UInt64, UInt64) -> Void) async throws {
        let total = sources.totalBytes
        var done: UInt64 = 0
        do {
            for (index, item) in sources.items.enumerated() {
                try Task.checkCancellation()
                let destination = folder.appending(path: item.file)
                let base = done
                progress(index + 1, base, total)
                do {
                    try await transfer.fetch(item.url, to: destination) { written in
                        progress(index + 1, base &+ UInt64(max(written, 0)), total)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let failure as Failure {
                    throw failure
                } catch {
                    throw Failure.transport(file: item.file, detail: "\(error)")
                }
                let found = try Self.measure(destination)
                guard found.bytes == item.bytes else {
                    throw Failure.sizeMismatch(file: item.file, expected: item.bytes, found: found.bytes)
                }
                guard found.sha256 == item.sha256 else {
                    throw Failure.hashMismatch(file: item.file, expected: item.sha256, found: found.sha256)
                }
                done = base &+ item.bytes
                progress(index + 1, done, total)
            }
        } catch {
            Self.remove(sources.items, in: folder)
            throw error
        }
    }

    /// A file's size and SHA-256, read in chunks so a 143 MB source never sits in memory.
    static func measure(_ file: URL) throws -> (bytes: UInt64, sha256: String) {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return (0, "")
        }
        defer { try? handle.close() }
        var digest = SHA256()
        var bytes: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            digest.update(data: chunk)
            bytes &+= UInt64(chunk.count)
        }
        return (bytes, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// A SHA-256 as the pack's lines write hashes: lowercase hex.
    public static func measure(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func remove(_ items: [WordPackSources.Item], in folder: URL) {
        for item in items {
            try? FileManager.default.removeItem(at: folder.appending(path: item.file))
        }
    }
}

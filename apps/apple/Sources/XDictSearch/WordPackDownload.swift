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
    /// task is cancelled. A response that is not a success is a failure, never a file. **`limit` is the size the
    /// manifest pins**, known before the first byte arrives: a response larger than it is refused and stopped, so a
    /// faulty or hostile server cannot stream unbounded bytes to disk before the size check is reached.
    func fetch(_ url: URL, to destination: URL, limit: UInt64,
               written: @escaping @Sendable (Int64) -> Void) async throws
}

/// The network, through `URLSession`, streaming each file to a temporary beside its destination and moving it into
/// place.
///
/// **The body is streamed through a session delegate, and the bytes are counted there** (2026-10-31): a task-specific
/// delegate receives no callbacks on macOS 27, which left `download(for:delegate:)`'s progress dead — and a download
/// whose progress never fires leaves the reader with a bar at zero while 185 MB arrive. Every guarantee the temporary
/// file's design had is kept: a response that is not a success is refused before any byte is written, the partial file
/// is deleted on every failure path, and the file is moved into place only when the whole body landed.
public struct URLSessionTransfer: WordPackTransfer {
    public init(session: URLSession = .shared) {
        self.session = session
    }

    private let session: URLSession

    public func fetch(_ url: URL, to destination: URL, limit: UInt64,
                      written: @escaping @Sendable (Int64) -> Void) async throws {
        try Task.checkCancellation()
        let file = url.lastPathComponent
        let folder = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw WordPackDownload.Failure.transport(file: file, detail: "\(error)")
        }
        // **The partial file sits beside its destination**, on the same volume, so the move into place is a rename;
        // the name is fixed, so a run that crashed has only one stale file to overwrite and none to accumulate.
        let partial = folder.appending(path: ".\(destination.lastPathComponent).partial")
        let stream = DownloadStream(partial: partial, file: file, limit: limit, written: written)
        // **The delegate belongs to the session, not the task** (2026-10-31): that is the delegate that receives
        // `didReceive data` on macOS 27, and a session made from the caller's configuration keeps the app's settings
        // and the tests' stubbed network.
        let streaming = URLSession(configuration: session.configuration, delegate: stream, delegateQueue: nil)
        defer { streaming.finishTasksAndInvalidate() }
        do {
            try await stream.download(streaming.dataTask(with: URLRequest(url: url)))
        } catch {
            stream.discard()
            throw error
        }
        do {
            try Self.move(partial, to: destination)
        } catch {
            Self.discard(partial)
            throw WordPackDownload.Failure.transport(file: file, detail: "\(error)")
        }
    }

    /// **A partial file this code will not keep is deleted here**: a failed status, a broken response or a failed move
    /// must not leave half a pack in the folder a build reads.
    private static func discard(_ partial: URL) {
        try? FileManager.default.removeItem(at: partial)
    }

    /// The downloaded file into its place: a rename where the destination is new, and `replaceItemAt` — the atomic
    /// replacement — where an earlier copy is there to be replaced.
    private static func move(_ partial: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
    }
}

/// **One download, streamed to a file and counted as it lands**: the session's data delegate, because on macOS 27 a
/// task-specific delegate receives no callbacks. It refuses a response that is not a success before writing a byte,
/// reports each chunk's new total, and answers exactly once — with `CancellationError` when the caller stopped it.
private final class DownloadStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    init(partial: URL, file: String, limit: UInt64, written: @escaping @Sendable (Int64) -> Void) {
        self.partial = partial
        self.file = file
        self.limit = limit
        self.cap = limit > UInt64(Int64.max) ? Int64.max : Int64(limit)
        self.written = written
    }

    private let partial: URL
    private let file: String
    /// The size the manifest pins, as its own case reports it.
    private let limit: UInt64
    /// The same size as a count no response may exceed.
    private let cap: Int64
    private let written: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var handle: FileHandle?
    private var count: Int64 = 0
    private var failure: (any Error)?
    private var cancelled = false
    private var finished = false
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, any Error>?

    /// Starts the task and waits for it: a success only when every chunk was written and the file closed.
    func download(_ task: URLSessionDataTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                self.task = task
                self.continuation = continuation
                let cancelled = self.cancelled
                lock.unlock()
                if cancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// The caller's task was cancelled: the download stops, and the partial file goes on the failure path that follows,
    /// so a cancel never leaves a download behind.
    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    /// Everything this stream wrote, deleted: a failed download leaves nothing for a build to read.
    func discard() {
        lock.lock()
        let handle = self.handle
        self.handle = nil
        lock.unlock()
        try? handle?.close()
        try? FileManager.default.removeItem(at: partial)
    }

    // MARK: - URLSessionDataDelegate

    /// **Redirects are followed, as they were through `download(for:)`**: GitHub's release downloads answer with a
    /// redirect to their object store, and a transport that refused a 3xx as an error would fail every one of them.
    /// Implementing this also keeps a redirect's headers out of `didReceive response` below, which judges the final one.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request)
    }

    /// **A response that is not a success is refused before any write**: no file is created, the body is not allowed to
    /// arrive, and the failure names the file and the status. **A declared length past the pinned size is refused the
    /// same way**, before a byte lands; a body that streams past it is stopped in `didReceive data` below.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            record(WordPackDownload.Failure.transport(file: file, detail: "HTTP \(status)"))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > 0, response.expectedContentLength > cap {
            record(WordPackDownload.Failure.tooLarge(file: file, limit: limit))
            completionHandler(.cancel)
            return
        }
        guard FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil) else {
            record(WordPackDownload.Failure.transport(file: file, detail: "could not create \(partial.lastPathComponent)"))
            completionHandler(.cancel)
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            lock.lock()
            self.handle = handle
            lock.unlock()
            completionHandler(.allow)
        } catch {
            record(WordPackDownload.Failure.transport(file: file, detail: "\(error)"))
            completionHandler(.cancel)
        }
    }

    /// Each chunk into the file and its new total out: the count is what the Settings row's bar reads. **The pinned
    /// size is a hard ceiling**: a chunk that would take the file past it is not written, the task is cancelled, and
    /// the failure says the response was larger than the manifest pins.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished, failure == nil, let handle else {
            lock.unlock()
            return
        }
        guard Int64(data.count) <= cap - count else {
            failure = WordPackDownload.Failure.tooLarge(file: file, limit: limit)
            lock.unlock()
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
            count += Int64(data.count)
            let now = count
            lock.unlock()
            written(now)
        } catch {
            failure = WordPackDownload.Failure.transport(file: file, detail: "\(error)")
            lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(error)
    }

    // MARK: - The one ending

    private func record(_ error: any Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    /// **One ending per download**: closes the file and answers the caller with a cancellation, the failure that ended
    /// it (a status, a write, a broken response, the session's timeout), or success.
    private func finish(_ error: (any Error)?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let handle = self.handle
        self.handle = nil
        let continuation = self.continuation
        self.continuation = nil
        let cancelled = self.cancelled
        let failure = self.failure
        lock.unlock()
        try? handle?.close()
        let result: Result<Void, any Error>
        if cancelled {
            result = .failure(CancellationError())
        } else if let failure {
            result = .failure(failure)
        } else if let error {
            // The session's own cancellation of a refused response is not the caller's cancel: the recorded failure
            // above has already answered that case. What is left is a real transport error.
            result = Self.isCancellation(error)
                ? .failure(CancellationError())
                : .failure(WordPackDownload.Failure.transport(file: file, detail: "\(error)"))
        } else {
            result = .success(())
        }
        continuation?.resume(with: result)
    }

    private static func isCancellation(_ error: (any Error)?) -> Bool {
        guard let error else { return false }
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
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
        /// The response was larger than the size the manifest pins: the transfer stopped at that size, before another
        /// byte was written, so a faulty or hostile server cannot fill the disk.
        case tooLarge(file: String, limit: UInt64)
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
                    try await transfer.fetch(item.url, to: destination, limit: item.bytes) { written in
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

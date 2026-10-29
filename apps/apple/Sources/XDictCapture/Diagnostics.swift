import Foundation

/// **A log a reader can hand back** (owner, 2026-10-29: "hover often does not appear… I cannot report it, it is hard to
/// describe"). One line per decision on the pointer, lookup and panel paths — what was asked, what the gate said, what was
/// read, what was shown or refused — written to `~/Library/Logs/XDict/` (the container's Logs folder under the sandbox),
/// rotated at two megabytes and kept three deep, and exported by Settings ▸ General ▸ Save Diagnostics… with the
/// environment a reader cannot be expected to describe.
///
/// **The words are withheld unless the reader says otherwise**: a line carries counts, kinds and reasons, never the text —
/// a log a reader sends is a log of what XDict did, not of what they were reading. `includeText` is the reader's switch,
/// off by default, and even then the text stays in this Mac's own log.
public final class Diagnostics: @unchecked Sendable {
    public static let shared = Diagnostics()
    /// The reader's switch: their words in their own log. Off unless chosen.
    public static let includeTextKey = "diagnostics.includeText"
    /// The log's own bounds: beyond this it rotates, and this many files are kept.
    public static let maxBytes = 2 << 20
    public static let keep = 3

    private let defaults: UserDefaults
    private let directory: URL
    /// The file's bound, injectable so a test does not have to write two megabytes to see it rotate.
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "ai.xdict.diagnostics")
    private var handle: FileHandle?
    private var written = 0

    /// `directory` is injectable for the tests; the app writes where a reader's Console and Finder both find it.
    public init(defaults: UserDefaults = .standard, directory: URL? = nil, maxBytes: Int = Diagnostics.maxBytes) {
        self.defaults = defaults
        self.directory = directory ?? Self.defaultDirectory
        self.maxBytes = maxBytes
    }

    public static var defaultDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appending(path: "Logs/XDict", directoryHint: .isDirectory)
    }

    /// The file written now.
    public var fileURL: URL { directory.appending(path: "diagnostics.log") }

    /// Whether the reader let their words into the log.
    public var includeText: Bool { defaults.bool(forKey: Self.includeTextKey) }

    /// The text as a line may carry it: itself when the reader allowed it, else how much of it there was.
    public func word(_ text: String) -> String {
        includeText ? text : "<withheld: \(text.count) chars>"
    }

    /// One event. `fields` are the facts a developer needs and a reader does not mind: kinds, counts, names of refusals.
    public func record(_ event: String, _ fields: [String: String] = [:]) {
        let stamp = Date().formatted(Self.stamp)
        let detail = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.escaped($0.value))" }.joined(separator: " ")
        let line = detail.isEmpty ? "\(stamp) \(event)\n" : "\(stamp) \(event) \(detail)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [self] in
            append(data)
        }
    }

    /// Everything the logs hold, newest last, bounded by `limit` bytes from the end.
    public func exportText(limit: Int = 4 << 20) -> String {
        queue.sync {
            flushLocked()
            var pieces: [String] = []
            for url in rotatedFiles().reversed() + [fileURL] {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                pieces.append(text)
            }
            let whole = pieces.joined()
            guard whole.utf8.count > limit else { return whole }
            // **The bound is bytes, and a line is the unit** (audit 2026-10-29 finding 4): `suffix` counted grapheme
            // clusters, so the tail could be several times the limit in UTF-8, and it could start inside a line. Whole
            // lines from the end keep it under the bound and keep every line whole — and a `String` is always valid
            // UTF-8, so no scalar is split.
            let marker = "… the log was longer; its last part follows\n"
            guard limit >= marker.utf8.count else {
                // **The bound outranks the sentence** (verify 2026-10-29): a limit below the marker's own bytes used to
                // return the marker whole, over the bound it claims. The marker is cut to what fits, character by
                // character, so even this answer is valid UTF-8 within `limit`.
                var fits = ""
                for character in marker {
                    guard fits.utf8.count + character.utf8.count <= limit else { break }
                    fits.append(character)
                }
                return fits
            }
            var budget = limit - marker.utf8.count
            var tail: [String] = []
            for line in whole.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
                let piece = String(line) + "\n"
                guard piece.utf8.count <= budget else { break }
                tail.append(piece)
                budget -= piece.utf8.count
            }
            return marker + tail.reversed().joined()
        }
    }

    // MARK: - The file

    private func append(_ data: Data) {
        do {
            if handle == nil {
                try open()
            }
            if written + data.count > maxBytes {
                rotate()
                try open()
            }
            try handle?.write(contentsOf: data)
            written += data.count
        } catch {
            // A log that cannot be written must never take the app with it; the next record tries again.
            handle = nil
        }
    }

    private func open() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        self.handle = handle
        written = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int).flatMap { $0 } ?? 0
    }

    /// `diagnostics.log` → `.1` → `.2`, the oldest dropped.
    private func rotate() {
        flushLocked()
        let manager = FileManager.default
        let oldest = directory.appending(path: "diagnostics.\(Self.keep - 1).log")
        try? manager.removeItem(at: oldest)
        for index in stride(from: Self.keep - 2, through: 1, by: -1) {
            let from = directory.appending(path: "diagnostics.\(index).log")
            let to = directory.appending(path: "diagnostics.\(index + 1).log")
            if manager.fileExists(atPath: from.path) { try? manager.moveItem(at: from, to: to) }
        }
        if manager.fileExists(atPath: fileURL.path) {
            try? manager.moveItem(at: fileURL, to: directory.appending(path: "diagnostics.1.log"))
        }
        written = 0
    }

    private func rotatedFiles() -> [URL] {
        (1..<Self.keep).map { directory.appending(path: "diagnostics.\($0).log") }
    }

    private func flushLocked() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    /// A value, not a formatter: `ISO8601DateFormatter` is not Sendable, and a line's stamp is all this needs.
    private static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// A value on one line: newlines and quotes would break the log's shape.
    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

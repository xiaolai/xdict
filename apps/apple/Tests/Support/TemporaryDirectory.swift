import Foundation

/// A directory of a test's own, removed when the test that made it lets it go. A class, so the lifetime is what cleans
/// up: XiaolaiDict once found 16,363 directories its tests had made and nothing had removed.
public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL

    /// `name` only labels it for a person reading `ls`; uniqueness comes from the UUID.
    public init(named name: String = "xdict") throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A path inside it, which the caller may create or not.
    public func appending(_ component: String) -> URL { url.appending(path: component) }

    deinit {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            FileHandle.standardError.write(Data("TemporaryDirectory: \(url.path) was not removed: \(error)\n".utf8))
        }
    }
}

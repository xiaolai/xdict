import Foundation
import Observation

/// **What About says, and the one thing it asks the network** (owner, 2026-10-29): the app's own numbers and the
/// licences it ships under, and — only when the reader taps — whether a newer release exists.
///
/// **Nothing leaves this Mac before that tap.** The check is one request to GitHub's own releases API, it says what it
/// found or that it could not ask, and it never asks again on its own.
@MainActor @Observable
public final class AboutModel {
    /// What the last check found.
    public enum Update: Equatable, Sendable {
        /// The reader has not asked.
        case notAsked
        /// The one request is in flight.
        case checking
        /// This release is the newest one GitHub lists.
        case current(latest: String)
        /// A newer release exists, and where to read about it.
        case available(latest: String, page: URL)
        /// The question could not be answered: the network, or a reply that was not a release.
        case failed
    }

    /// The release this copy is (`CFBundleShortVersionString`).
    public let version: String
    /// Its build number (`CFBundleVersion`).
    public let build: String
    /// What the last check found.
    public private(set) var update: Update = .notAsked

    /// Where the newest release is described, and where a reader reads about it.
    public static let releases = URL(string: "https://api.github.com/repos/xiaolai/xdict/releases/latest")!
    /// The page a reader opens to read the notes.
    public static let page = URL(string: "https://github.com/xiaolai/xdict/releases")!

    private let fetch: @Sendable (URL) async throws -> Data

    /// The numbers of the running app, read from its own bundle.
    public convenience init(bundle: Bundle = .main) {
        self.init(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        )
    }

    /// A model over given numbers, its network replaced in the tests (`nil` asks GitHub).
    public init(version: String, build: String, fetch: (@Sendable (URL) async throws -> Data)? = nil) {
        self.version = version
        self.build = build
        self.fetch = fetch ?? Self.github
    }

    /// **One question, on the reader's tap**: what does GitHub list as the newest release?
    public func check() async {
        update = .checking
        do {
            guard let latest = Self.latestRelease(in: try await fetch(Self.releases)) else {
                update = .failed
                return
            }
            update = Self.isNewer(latest, than: version)
                ? .available(latest: latest, page: Self.page)
                : .current(latest: latest)
        } catch {
            update = .failed
        }
    }

    /// The `tag_name` of a release document, without its leading `v`; `nil` when the reply is not one.
    public static func latestRelease(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { return nil }
        let trimmed = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether `candidate` is a later version than `current`, component by component and numerically, so `0.10.0` is
    /// newer than `0.9.9` — which a string comparison would get wrong.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(candidate)
        let right = components(current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
    }

    private static let github: @Sendable (URL) async throws -> Data = { url in
        var request = URLRequest(url: url)
        request.setValue("XDict", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

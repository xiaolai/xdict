import Foundation
import Testing
import XDictUI

/// **About's numbers and its one question** (owner, 2026-10-29): the versions are compared as numbers, not as text, and
/// every answer GitHub can give — a newer release, the same release, nothing readable, no network — lands in its own
/// state, so the panel can say which happened instead of going quiet.
@MainActor
struct AboutModelTests {
    nonisolated static let release = Data(#"{"tag_name":"v0.7.0","name":"0.7.0"}"#.utf8)

    // MARK: versions

    @Test func aLaterReleaseIsNewerComponentByComponent() {
        #expect(AboutModel.isNewer("0.7.0", than: "0.6.1"))
        #expect(AboutModel.isNewer("0.10.0", than: "0.9.9"))   // text comparison would call 0.9.9 newer
        #expect(AboutModel.isNewer("1.0", than: "0.99.99"))
        #expect(AboutModel.isNewer("0.6.1.1", than: "0.6.1"))
        #expect(AboutModel.isNewer("0.6.10", than: "0.6.9"))
    }

    @Test func theSameOrAnEarlierReleaseIsNotNewer() {
        #expect(!AboutModel.isNewer("0.6.1", than: "0.6.1"))
        #expect(!AboutModel.isNewer("0.6", than: "0.6.0"))
        #expect(!AboutModel.isNewer("0.6.0", than: "0.6.1"))
        #expect(!AboutModel.isNewer("0.6.9", than: "0.6.10"))
    }

    // MARK: the release document

    @Test func theTagNamesTheRelease() {
        #expect(AboutModel.latestRelease(in: Self.release) == "0.7.0")
        #expect(AboutModel.latestRelease(in: Data(#"{"tag_name":"0.8.0"}"#.utf8)) == "0.8.0")
    }

    @Test func aReplyThatIsNotAReleaseNamesNothing() {
        #expect(AboutModel.latestRelease(in: Data(#"{"message":"Not Found"}"#.utf8)) == nil)
        #expect(AboutModel.latestRelease(in: Data(#"{"tag_name":"v"}"#.utf8)) == nil)
        #expect(AboutModel.latestRelease(in: Data("not json".utf8)) == nil)
    }

    // MARK: the check

    @Test func aNewerReleaseIsOffered() async {
        let model = AboutModel(version: "0.6.1", build: "7", fetch: { _ in Self.release })
        #expect(model.update == .notAsked)
        await model.check()
        #expect(model.update == .available(latest: "0.7.0", page: AboutModel.page))
    }

    @Test func thisCopyBeingTheNewestIsSaid() async {
        let model = AboutModel(version: "0.7.0", build: "8", fetch: { _ in Self.release })
        await model.check()
        #expect(model.update == .current(latest: "0.7.0"))
    }

    @Test func noNetworkIsItsOwnAnswer() async {
        struct Offline: Error {}
        let model = AboutModel(version: "0.6.1", build: "7", fetch: { _ in throw Offline() })
        await model.check()
        #expect(model.update == .failed)
    }

    @Test func anUnreadableReplyIsAFailureNotAnAnswer() async {
        let model = AboutModel(version: "0.6.1", build: "7", fetch: { _ in Data("nonsense".utf8) })
        await model.check()
        #expect(model.update == .failed)
    }

    /// The question is the releases API's, not a page's: the URL the model asks is the one it names.
    @Test func theCheckAsksTheReleasesAPI() async {
        final class Asked: @unchecked Sendable { var url: URL? }
        let asked = Asked()
        let model = AboutModel(version: "0.6.1", build: "7", fetch: { url in
            asked.url = url
            return Self.release
        })
        await model.check()
        #expect(asked.url == AboutModel.releases)
        #expect(AboutModel.releases.absoluteString
            == "https://api.github.com/repos/xiaolai/xdict/releases/latest")
    }
}

import Foundation
import Testing
import XDictTestSupport
import XDictContract
@testable import XDictUI

/// **Sync's running state, its last success and disconnect** (UI40), and the notification refusal's way out (UI41).
@MainActor
struct SyncPassTests {
    static func defaults() -> UserDefaults {
        let suite = "ai.xdict.tests.sync-pass." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    static let folder = Data("bookmark".utf8)

    /// While a pass runs the pane says so, and a second Sync Now starts nothing.
    @Test func aRunningPassIsSaidAndNotRepeated() async {
        let gate = AsyncStream<Void>.makeStream()
        var runs = 0
        let pass = SyncPass(defaults: Self.defaults(), now: { Date(timeIntervalSince1970: 100) },
                            open: { _ in ("/tmp/folder", {}) },
                            perform: { _ in
                                runs += 1
                                var iterator = gate.stream.makeAsyncIterator()
                                _ = await iterator.next()
                                return SyncReport(exported: 1, peers: 1, added: 3, skipped: 0)
                            })
        let first = Task { await pass.run(Self.folder) }
        #expect(await eventually { pass.isRunning })
        await pass.run(Self.folder)
        #expect(runs == 1)
        gate.continuation.yield()
        await first.value
        #expect(!pass.isRunning)
        #expect(pass.phase == .synced(added: 3, peers: 1))
        #expect(pass.lastSuccess == Date(timeIntervalSince1970: 100))
    }

    /// A pass that cannot finish is said, and the last success it did not replace stays.
    @Test func aFailedPassKeepsTheLastSuccess() async {
        let defaults = Self.defaults()
        let report = Box<SyncReport?>(SyncReport(exported: 1, peers: 0, added: 0, skipped: 0))
        let pass = SyncPass(defaults: defaults, now: { Date(timeIntervalSince1970: 50) },
                            open: { _ in ("/tmp/folder", {}) }, perform: { _ in report.value })
        await pass.run(Self.folder)
        #expect(pass.phase == .synced(added: 0, peers: 0))
        report.value = nil
        await pass.run(Self.folder)
        #expect(pass.phase == .failed)
        #expect(pass.lastSuccess == Date(timeIntervalSince1970: 50))
        // Kept across launches.
        let again = SyncPass(defaults: defaults, open: { _ in nil }, perform: { _ in nil })
        #expect(again.lastSuccess == Date(timeIntervalSince1970: 50))
    }

    /// A folder that no longer opens is its own sentence, not a failed sync.
    @Test func aFolderThatDoesNotOpenIsSaid() async {
        let pass = SyncPass(defaults: Self.defaults(), open: { _ in nil }, perform: { _ in nil })
        await pass.run(Self.folder)
        #expect(pass.phase == .folderUnavailable)
        await pass.run(nil)
        #expect(pass.phase == .noFolder)
    }

    /// **Disconnect stops future sync** and forgets only the bookmark and the last success: the folder's files and this
    /// Mac's history are not touched (nothing here can reach them).
    @Test func disconnectForgetsTheFolder() async {
        let defaults = Self.defaults()
        let preferences = LearningPreferences(defaults: defaults)
        preferences.setSyncFolder(Self.folder)
        let pass = SyncPass(defaults: defaults, open: { _ in ("/tmp/folder", {}) },
                            perform: { _ in SyncReport(exported: 1, peers: 0, added: 0, skipped: 0) })
        await pass.run(Self.folder)
        #expect(pass.lastSuccess != nil)
        pass.disconnect(preferences)
        #expect(preferences.syncFolder == nil)
        #expect(pass.lastSuccess == nil)
        #expect(pass.phase == .idle)
    }

    /// The access to the folder is handed back after every pass.
    @Test func theFolderAccessIsHandedBack() async {
        var stopped = 0
        let pass = SyncPass(defaults: Self.defaults(), open: { _ in ("/tmp/folder", { stopped += 1 }) },
                            perform: { _ in nil })
        await pass.run(Self.folder)
        #expect(stopped == 1)
    }

    /// **Open Notification Settings** goes to XDict's own row, then to the pane, then to System Settings itself.
    @Test func theNotificationLinkFallsBack() {
        let links = NotificationSettingsLink.candidates(bundle: "ai.xdict.app")
        #expect(links.first?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=ai.xdict.app")
        #expect(links.dropFirst().first?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #expect(NotificationSettingsLink.candidates(bundle: nil).count == 1)
    }

    /// **The privacy sentence is true before and after sync** (UI39): local by default, and what a folder changes.
    @Test func thePrivacyWordsFollowTheFolder() {
        let local = String(localized: LearningSettings.historyPrivacy(syncing: false))
        let synced = String(localized: LearningSettings.historyPrivacy(syncing: true))
        #expect(local != synced)
        #expect(!local.contains("Nothing is sent anywhere"))
        #expect(synced.contains("folder"))
    }

}

/// A value a main-actor closure reads after the test changes it (such a closure is Sendable, so it cannot capture a
/// `var`).
@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

import Foundation
import Testing
import XDictUI

/// **Launch at login goes through `SMAppService`**, and Settings shows what the system says, not what was asked: an
/// approval still pending in System Settings is its own state, and a refusal is said, never swallowed.
@MainActor
struct LaunchAtLoginTests {
    final class FakeService: LoginItemService {
        var status: LoginItemStatus = .notRegistered
        var failNext = false
        var calls: [String] = []

        func register() throws {
            calls.append("register")
            if failNext { throw CocoaError(.featureUnsupported) }
            status = .enabled
        }

        func unregister() throws {
            calls.append("unregister")
            status = .notRegistered
        }

        func openSystemSettings() {
            calls.append("openSystemSettings")
        }
    }

    /// **Only the reader's switch registers** (XiaolaiDict's Startup section, ported): making the row and reading the
    /// system again, in every state, change nothing — no launch and no Settings visit makes XDict a login item.
    @Test func nothingRegistersButTheSwitch() {
        for status: LoginItemStatus in [.enabled, .notRegistered, .requiresApproval, .notFound] {
            let service = FakeService()
            service.status = status
            let item = LaunchAtLogin(service: service)
            item.refresh()
            #expect(service.calls.isEmpty, "\(status): \(service.calls)")
            #expect(item.status == status)
        }
    }

    /// **A pending approval offers the way to it**: Login Items in System Settings, opened by the reader's button, and
    /// only in that state. Red while the row has no way to the approval it is waiting for.
    @Test func aPendingApprovalOffersLoginItemsSettings() {
        let service = FakeService()
        service.status = .requiresApproval
        let item = LaunchAtLogin(service: service)
        #expect(item.needsApproval)
        item.openLoginItems()
        #expect(service.calls == ["openSystemSettings"])
        for status: LoginItemStatus in [.enabled, .notRegistered, .notFound] {
            service.status = status
            item.refresh()
            #expect(!item.needsApproval, "\(status)")
        }
    }

    @Test func turningItOnRegistersAndShowsTheStatus() {
        let service = FakeService()
        let item = LaunchAtLogin(service: service)
        #expect(!item.isOn)
        item.set(true)
        #expect(service.calls == ["register"])
        #expect(item.isOn)
        #expect(item.status == .enabled)
        #expect(item.failure == nil)
        item.set(false)
        #expect(service.calls == ["register", "unregister"])
        #expect(!item.isOn)
    }

    @Test func aPendingApprovalIsShownAsSuch() {
        let service = FakeService()
        service.status = .requiresApproval
        let item = LaunchAtLogin(service: service)
        #expect(item.isOn, "registered, waiting for the reader's approval")
        #expect(String(localized: LaunchAtLogin.sentence(.requiresApproval))
                != String(localized: LaunchAtLogin.sentence(.enabled)))
    }

    @Test func aRefusalIsSaid() {
        let service = FakeService()
        service.failNext = true
        let item = LaunchAtLogin(service: service)
        item.set(true)
        #expect(!item.isOn)
        #expect(item.failure != nil)
    }

    @Test func everyStatusHasItsOwnSentence() {
        let all: [LoginItemStatus] = [.enabled, .notRegistered, .requiresApproval, .notFound]
        let sentences = Set(all.map { String(localized: LaunchAtLogin.sentence($0)) })
        #expect(sentences.count == all.count)
    }
}

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

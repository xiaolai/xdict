import Foundation
import Observation
import ServiceManagement
import os

/// What the system says of XDict as a login item (`SMAppService.Status`, kept to the cases the reader is shown).
public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    /// Registered, waiting for the reader's approval in System Settings ▸ General ▸ Login Items.
    case requiresApproval
    case notFound
}

/// The login item service; `SMAppService.mainApp` in the app, a fake in tests, so no test changes the Mac it runs on.
@MainActor
public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// The app itself as its login item.
@MainActor
public final class MainAppLoginItem: LoginItemService {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// **Launch at login, in Settings** (plan-macos-v1 WI-9): the switch asks the system, then shows what the system says
/// (`status`), not what was asked; a refusal is said under it (`failure`) and logged.
@MainActor
@Observable
public final class LaunchAtLogin {
    @ObservationIgnored private let service: any LoginItemService
    public private(set) var status: LoginItemStatus
    public private(set) var failure: String?

    public init(service: any LoginItemService) {
        self.service = service
        status = service.status
    }

    /// On while registered, approved or not.
    public var isOn: Bool { status == .enabled || status == .requiresApproval }

    public func set(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            failure = nil
        } catch {
            failure = error.localizedDescription
            Logger(subsystem: "ai.xdict.app", category: "login-item")
                .error("the login item could not be changed: \(String(describing: error), privacy: .public)")
        }
        status = service.status
    }

    /// Read the system again: an approval given in System Settings changes it with XDict open.
    public func refresh() { status = service.status }

    public static func sentence(_ status: LoginItemStatus) -> LocalizedStringResource {
        switch status {
        case .enabled: LocalizedStringResource("XDict opens when you log in.")
        case .notRegistered: LocalizedStringResource("XDict does not open when you log in.")
        case .requiresApproval:
            LocalizedStringResource("Waiting for your approval in System Settings ▸ General ▸ Login Items.")
        case .notFound: LocalizedStringResource("macOS cannot find XDict to open at login.")
        }
    }
}

import Foundation
import Observation

/// What the Dictionaries pane shows over itself: one thing at a time (ADR-0012 d.3).
public enum SettingsPresentation: Equatable, Sendable {
    case none
    /// The open panel: Add MDX Files…, Locate….
    case importer
    /// One dictionary's details (`LibraryDetail`), by its id.
    case details(UUID)
    /// The Apple import (ADR-0011, WI-5).
    case appleImport
}

/// **Opening Settings on a dictionary is routed, not hoped for** (ADR-0012 d.4): the pane to show, the dictionary to
/// select once the pane is there, and the one presentation the pane holds (d.3). Every way that once opened the Library
/// window asks this instead; it opens Settings itself (`open`, SwiftUI's `openSettings`, handed over by a view that lives
/// as long as the app), so it works cold, from another pane, over Details, and from the menu bar alone.
@MainActor
@Observable
public final class SettingsRoute {
    public static let shared = SettingsRoute()

    /// The pane in front; `TabView(selection:)` reads and writes it.
    public var pane: SettingsTab = .dictionaries
    /// The dictionary to select when the pane next resolves; taken once.
    public private(set) var pendingSelection: UUID?
    /// Whether the dictionary last asked for had gone by the time the pane looked (said in the strip).
    public private(set) var removedNotice = false
    public private(set) var presentation: SettingsPresentation = .none
    /// The one request that came while something else was shown; shown when that is dismissed.
    public private(set) var queued: SettingsPresentation?
    /// Opens the Settings window. Unset until a view hands it over; then every route call opens it.
    @ObservationIgnored public var open: (@MainActor () -> Void)?

    public init(open: (@MainActor () -> Void)? = nil) {
        self.open = open
    }

    /// Settings ▸ Dictionaries, with `dictionary` selected when given. Details over another dictionary close.
    public func show(_ dictionary: UUID?) {
        pane = .dictionaries
        pendingSelection = dictionary
        removedNotice = false
        if case .details = presentation {
            presentation = .none
            queued = nil
        }
        open?()
    }

    /// Settings ▸ Dictionaries with the open panel up (File ▸ Add Dictionaries…, the setup board, the main window).
    public func requestImport() {
        pane = .dictionaries
        request(.importer)
        open?()
    }

    /// Shows `wanted` if nothing is shown (or it already is); otherwise queues it behind what is. True when shown.
    @discardableResult
    public func request(_ wanted: SettingsPresentation) -> Bool {
        if presentation == .none || presentation == wanted {
            presentation = wanted
            return true
        }
        queued = wanted
        return false
    }

    /// Closes what is shown, and shows what was queued behind it.
    public func dismiss() {
        presentation = queued ?? .none
        queued = nil
    }

    /// Closes `shown` only if it is still what is shown: a sheet's or panel's binding can write after it has gone.
    public func dismiss(_ shown: SettingsPresentation) {
        guard presentation == shown else { return }
        dismiss()
    }

    /// Locate… from the details: the sheet gives way to the open panel.
    public func locate() {
        request(.importer)
        dismiss()
    }

    public enum Resolution: Equatable, Sendable {
        /// Nothing was asked: the selection stays the reader's.
        case unchanged
        case select(UUID)
        /// The asked dictionary is gone: the selection falls back to none, and `removedNotice` says so.
        case removed
    }

    /// What the pane's selection becomes, given its dictionaries; the pending selection is taken.
    public func resolveSelection(among ids: [UUID]) -> Resolution {
        guard let wanted = pendingSelection else { return .unchanged }
        pendingSelection = nil
        if ids.contains(wanted) { return .select(wanted) }
        removedNotice = true
        return .removed
    }
}

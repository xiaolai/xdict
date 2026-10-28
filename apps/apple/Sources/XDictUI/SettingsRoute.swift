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
    /// Choosing the word data's file (plan-word-exploration WI-5).
    case wordPack
}

/// **Opening Settings on a dictionary is routed, not hoped for** (ADR-0012 d.4): the pane to show, the dictionary to
/// select once the pane is there, and the one presentation the pane holds (d.3). Every way that once opened the Library
/// window asks this instead; it opens Settings itself (`open`, SwiftUI's `openSettings`, handed over by a view that lives
/// as long as the app), so it works cold, from another pane, over Details, and from the menu bar alone.
@MainActor
@Observable
public final class SettingsRoute {
    public static let shared = SettingsRoute()

    /// The pane in front; `TabView(selection:)` reads and writes it. Leaving a revealed row's pane drops that reveal.
    public var pane: SettingsTab = .dictionaries {
        didSet { if pane != revealedPane { revealed = nil } }
    }
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

    /// **Settings ▸ Setup** (ADR-0012, amended 2026-10-20): the setup board is a pane of Settings now, so the first launch,
    /// the app menu and General's row all land here rather than in a window of its own.
    public func showSetup() {
        pane = .setup
        open?()
    }

    /// **Any pane, by name** (plan-setup-v2 WI-2): the setup board's rows open General (hover's key, settle time, the
    /// apps hover never reads) and AI, and neither is a dictionary, so neither goes through `show(_:)`.
    public func showPane(_ pane: SettingsTab) {
        self.pane = pane
        open?()
    }

    /// The row a Settings search last revealed (UI30); the pane holding it scrolls to it, and opens the disclosure it
    /// sits in.
    public private(set) var revealed: SettingsSearch.Anchor?
    /// Each reveal is an action, even when its target is the same as last time.
    public private(set) var revealSerial = 0
    @ObservationIgnored private var revealedPane: SettingsTab?

    /// **A search result, revealed** (UI30): its pane in front and its row marked for the row's own marker
    /// (`settingsAnchor(_:)`) to scroll to once it is drawn.
    public func reveal(_ item: SettingsSearch.Item) {
        revealedPane = item.pane
        revealed = item.anchor
        pane = item.pane
        revealSerial += 1
        open?()
    }

    /// Completes one scroll request; an older one must never consume a newer request.
    public func didReveal(serial: Int) {
        guard serial == revealSerial else { return }
        revealed = nil
    }

    /// **Add Apple Dictionaries… from the setup board** (plan-setup-v2 WI-2): the sheet belongs to the Dictionaries pane
    /// (ADR-0012 d.3, one presentation), so the row opens Settings there with the sheet up, as `requestImport()` does
    /// for the open panel.
    public func requestAppleImport() {
        pane = .dictionaries
        request(.appleImport)
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

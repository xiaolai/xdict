import Carbon.HIToolbox
import XDictBase
import os

/// Why a combination could not be registered, **by kind**: the view layer words it (`AnywhereSentences`).
public enum RegistrationRefusal: Hashable, Sendable {
    /// XDict itself already holds this combination.
    case heldByXDict
    /// XDict once held it and Carbon would not release it; it is free again once the app quits.
    case unreleasedByXDict
    /// Carbon's exclusive registration answered "exists": another app holds it.
    case takenByAnotherApp
    /// Any other status Carbon answered, kept: it is what a reader can quote when asking for help.
    case status(Int32)
}

/// A system-wide keyboard shortcut (plan-macos-v1 WI-8; moved from XiaolaiDict with its tests). Carbon's
/// `RegisterEventHotKey` is still the API for this that needs no permission prompt — a global `NSEvent` monitor for keys
/// needs Input Monitoring. Released when the value is.
@MainActor
public final class Hotkey {
    public struct RegistrationFailed: Error, Equatable {
        public let reason: RegistrationRefusal
        public init(_ reason: RegistrationRefusal) { self.reason = reason }
    }

    public let shortcut: Shortcut
    private let id: UInt32
    private let center: HotkeyCenter

    fileprivate init(shortcut: Shortcut, id: UInt32, center: HotkeyCenter) {
        self.shortcut = shortcut
        self.id = id
        self.center = center
    }

    isolated deinit {
        center.unregister(id)
    }
}

/// What XDict needs from Carbon — the seam tests replace.
@MainActor
public protocol HotkeyBackend {
    /// Installs the one application-wide handler. `route` returns whether the press was handled.
    func installHandler(_ route: @escaping @MainActor (EventHotKeyID) -> OSStatus) -> OSStatus
    func register(_ shortcut: Shortcut, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?)
    func unregister(_ reference: EventHotKeyRef) -> OSStatus
}

/// Carbon's hot-key plumbing, kept in one place: one application-wide handler, installed once and never removed, which
/// routes each press to the registration whose ID it carries. A press that is not XDict's is passed on untouched.
@MainActor
public final class HotkeyCenter {
    public static let shared = HotkeyCenter(backend: CarbonHotkeyBackend())
    /// "XDCT": marks XDict's registrations among every hot key the process sees.
    public static let signature = OSType(0x5844_4354)

    private let backend: any HotkeyBackend
    private let log = Logger(subsystem: XDictIdentity.app, category: "hotkey")
    private var installed = false
    private var registrations: [UInt32: (shortcut: Shortcut, reference: EventHotKeyRef, action: @MainActor () -> Void)] = [:]
    private var nextID: UInt32 = 1
    /// Shortcuts Carbon failed to release: XDict no longer routes them, but Carbon may still hold them for XDict, so a
    /// later conflict on one is XDict's own, not another app's.
    private var unreleased: [Shortcut] = []

    public init(backend: any HotkeyBackend) {
        self.backend = backend
    }

    /// Exclusive: while XDict holds the shortcut, no other app's registration fires on it.
    public func register(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void)
        throws(Hotkey.RegistrationFailed) -> Hotkey {
        guard !registrations.values.contains(where: { $0.shortcut == shortcut }) else {
            throw Hotkey.RegistrationFailed(.heldByXDict)
        }
        guard !unreleased.contains(shortcut) else { throw Hotkey.RegistrationFailed(.unreleasedByXDict) }
        if !installed {
            let status = backend.installHandler { [weak self] id in self?.route(id) ?? OSStatus(eventNotHandledErr) }
            guard status == noErr else { throw Hotkey.RegistrationFailed(Self.refusal(status)) }
            installed = true
        }
        let id = nextID
        nextID += 1
        let (status, reference) = backend.register(shortcut, id: EventHotKeyID(signature: Self.signature, id: id))
        guard status == noErr, let reference else { throw Hotkey.RegistrationFailed(Self.refusal(status)) }
        registrations[id] = (shortcut, reference, action)
        return Hotkey(shortcut: shortcut, id: id, center: self)
    }

    private static func refusal(_ status: OSStatus) -> RegistrationRefusal {
        status == OSStatus(eventHotKeyExistsErr) ? .takenByAnotherApp : .status(status)
    }

    /// The action for the press, or "not handled" for any hot key that is not one of XDict's.
    public func route(_ pressed: EventHotKeyID) -> OSStatus {
        guard pressed.signature == Self.signature, let registration = registrations[pressed.id] else {
            return OSStatus(eventNotHandledErr)
        }
        registration.action()
        return noErr
    }

    fileprivate func unregister(_ id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        let status = backend.unregister(registration.reference)
        if status != noErr {
            unreleased.append(registration.shortcut)
            log.error("UnregisterEventHotKey failed (OSStatus \(status)); the shortcut may stay claimed until XDict quits")
        }
    }

    /// How many shortcuts are registered.
    public var registrationCount: Int { registrations.count }

    /// **The one Escape claim this centre makes**, shared by every surface Escape dismisses.
    public private(set) lazy var escape = EscapeStack(hotkeys: self)
}

/// **One Escape claim, and a stack of what it dismisses — topmost first** (moved from XiaolaiDict).
///
/// The panel never becomes key (it must not take the reader's next keystroke), so an ordinary key event never reaches
/// it, and a global key monitor needs Input Monitoring and cannot consume the press. So bare Escape is claimed as a hot
/// key — a deliberate departure from the guidance that an app should not take an unmodified key from the app in front,
/// bounded by holding the claim only while something it dismisses is on screen. The first press dismisses the topmost
/// surface; the last one out gives Escape back.
@MainActor
public final class EscapeStack {
    /// Escape with no modifiers. Carbon's hot keys match modifiers exactly, so ⇧⎋ and ⌘⎋ stay with the app in front.
    public static let shortcut = Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)

    /// A surface's place in the stack. Opaque: all an owner can do with one is hand it back.
    public struct Entry: Equatable { fileprivate let id: Int }

    private unowned let hotkeys: HotkeyCenter
    private var held: Hotkey?
    private var handlers: [(entry: Entry, dismiss: @MainActor () -> Void)] = []
    private var nextID = 0
    private let log = Logger(subsystem: XDictIdentity.app, category: "hotkey")

    fileprivate init(hotkeys: HotkeyCenter) {
        self.hotkeys = hotkeys
    }

    /// Whether Escape is XDict's right now.
    public var isClaimed: Bool { held != nil }
    public var depth: Int { handlers.count }

    /// Puts a surface on top, claiming Escape if this is the first. The entry is returned even when the claim is
    /// refused, so the next push tries again.
    public func push(_ dismiss: @escaping @MainActor () -> Void) -> Entry {
        nextID += 1
        let entry = Entry(id: nextID)
        handlers.append((entry, dismiss))
        claimIfNeeded()
        return entry
    }

    /// Takes a surface out, wherever it is, and gives Escape back when none is left.
    public func pop(_ entry: Entry) {
        handlers.removeAll { $0.entry == entry }
        if handlers.isEmpty { held = nil }
    }

    public func contains(_ entry: Entry) -> Bool { handlers.contains { $0.entry == entry } }

    private func claimIfNeeded() {
        guard held == nil, !handlers.isEmpty else { return }
        do {
            held = try hotkeys.register(Self.shortcut) { [weak self] in self?.handlers.last?.dismiss() }
        } catch {
            // The click-away dismissal is left; logged loudly, since nothing on screen says Escape went elsewhere.
            log.error("Escape not claimed for \(self.handlers.count, privacy: .public) surface(s): \(String(describing: error), privacy: .public)")
        }
    }
}

/// The real backend. Carbon delivers hot-key events on the main thread, which is what makes `assumeIsolated` sound. The
/// handler takes no context pointer — it routes through a static — so nothing it refers to can be freed under it.
public struct CarbonHotkeyBackend: HotkeyBackend {
    @MainActor private static var route: ((EventHotKeyID) -> OSStatus)?

    public init() {}

    public func installHandler(_ route: @escaping @MainActor (EventHotKeyID) -> OSStatus) -> OSStatus {
        Self.route = route
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                return MainActor.assumeIsolated { CarbonHotkeyBackend.route?(id) ?? OSStatus(eventNotHandledErr) }
            },
            1, &pressed, nil, nil)
    }

    public func register(_ shortcut: Shortcut, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        return (status, reference)
    }

    public func unregister(_ reference: EventHotKeyRef) -> OSStatus {
        UnregisterEventHotKey(reference)
    }
}

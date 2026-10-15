import Carbon.HIToolbox
import Testing
import XDictAnywhere

/// Carbon's hot-key calls, recorded instead of made: registering real global shortcuts from a test would take them from
/// the reader. Moved from XiaolaiDict (`FakeHotkeyBackend`).
@MainActor
final class FakeHotkeyBackend: HotkeyBackend {
    var installs = 0
    var registered: [EventHotKeyID] = []
    var shortcuts: [Shortcut] = []
    var unregistered = 0
    var registerStatus = noErr
    var unregisterStatus = noErr
    /// Combinations this fake answers "another app has it" for, so a test can refuse **one** shortcut rather than every
    /// registration — and so assert that the reader keeps what they had.
    var refused: [Shortcut] = []

    func installHandler(_ route: @escaping @MainActor (EventHotKeyID) -> OSStatus) -> OSStatus {
        installs += 1
        return noErr
    }

    func register(_ shortcut: Shortcut, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?) {
        guard registerStatus == noErr else { return (registerStatus, nil) }
        guard !refused.contains(shortcut) else { return (OSStatus(eventHotKeyExistsErr), nil) }
        registered.append(id)
        shortcuts.append(shortcut)
        return (noErr, EventHotKeyRef(bitPattern: Int(id.id)))
    }

    func unregister(_ reference: EventHotKeyRef) -> OSStatus {
        unregistered += 1
        return unregisterStatus
    }
}

/// Hot keys are routed by the ID each press carries, registered exclusively, and cleaned up with their status checked;
/// Escape is claimed once for every surface it dismisses. Moved from XiaolaiDict (`HotkeyTests`).
@MainActor
struct HotkeyTests {
    private let d = Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))
    private let e = Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(controlKey | optionKey))

    private func press(_ id: UInt32, signature: OSType = HotkeyCenter.signature) -> EventHotKeyID {
        EventHotKeyID(signature: signature, id: id)
    }

    /// Found by audit in XiaolaiDict: every registration shared ID 1 and every press ran every action.
    @Test func aPressRunsOnlyItsOwnAction() throws {
        let center = HotkeyCenter(backend: FakeHotkeyBackend())
        var fired: [String] = []
        let first = try center.register(d) { fired.append("d") }
        let second = try center.register(e) { fired.append("e") }
        #expect(center.route(press(2)) == noErr)
        #expect(fired == ["e"])
        withExtendedLifetime((first, second)) {}
    }

    /// Another app's hot key, or an ID XDict never issued, is passed on untouched.
    @Test func aPressThatIsNotXDictsIsNotHandled() throws {
        let center = HotkeyCenter(backend: FakeHotkeyBackend())
        let hotkey = try center.register(d) { Issue.record("ran for a press that was not its own") }
        #expect(center.route(press(1, signature: OSType(0x4F54_4852))) == OSStatus(eventNotHandledErr))
        #expect(center.route(press(9)) == OSStatus(eventNotHandledErr))
        withExtendedLifetime(hotkey) {}
    }

    @Test func registrationIsExclusiveAndTheHandlerInstalledOnce() throws {
        let backend = FakeHotkeyBackend()
        let center = HotkeyCenter(backend: backend)
        let hotkeys = [try center.register(d) {}, try center.register(e) {}]
        #expect(backend.installs == 1)
        #expect(backend.registered.count == 2)
        withExtendedLifetime(hotkeys) {}
    }

    /// Carbon's "exists" is another app's claim, by kind — the view layer words it.
    @Test func aConflictIsReportedAsAnotherAppsClaim() {
        let backend = FakeHotkeyBackend()
        backend.registerStatus = OSStatus(eventHotKeyExistsErr)
        let center = HotkeyCenter(backend: backend)
        #expect(throws: Hotkey.RegistrationFailed(.takenByAnotherApp)) { try center.register(d) {} }
        backend.registerStatus = OSStatus(-50)
        #expect(throws: Hotkey.RegistrationFailed(.status(-50))) { try center.register(d) {} }
        #expect(center.registrationCount == 0)
    }

    /// A combination XDict already holds is refused before Carbon is asked — so Carbon's "exists" can only mean another
    /// app, and saying so is true.
    @Test func ourOwnDuplicateIsNotBlamedOnAnotherApp() throws {
        let backend = FakeHotkeyBackend()
        let center = HotkeyCenter(backend: backend)
        let held = try center.register(d) {}
        #expect(throws: Hotkey.RegistrationFailed(.heldByXDict)) { try center.register(d) {} }
        #expect(backend.registered.count == 1)
        withExtendedLifetime(held) {}
    }

    /// After a failed release Carbon may still hold the shortcut for XDict: registering it again says it is XDict's own.
    @Test func aShortcutCarbonWouldNotReleaseIsStillXDicts() throws {
        let backend = FakeHotkeyBackend()
        backend.unregisterStatus = OSStatus(eventHotKeyInvalidErr)
        let center = HotkeyCenter(backend: backend)
        var hotkey: Hotkey? = try center.register(d) {}
        hotkey = nil
        #expect(throws: Hotkey.RegistrationFailed(.unreleasedByXDict)) { try center.register(d) {} }
        #expect(backend.registered.count == 1, "Carbon was asked again")
        _ = hotkey
    }

    /// Released, a hot key is unregistered with Carbon and stops routing.
    @Test func releasingAHotkeyUnregistersIt() throws {
        let backend = FakeHotkeyBackend()
        let center = HotkeyCenter(backend: backend)
        var hotkey: Hotkey? = try center.register(d) {}
        #expect(center.registrationCount == 1)
        hotkey = nil
        #expect(backend.unregistered == 1)
        #expect(center.registrationCount == 0)
        #expect(center.route(press(1)) == OSStatus(eventNotHandledErr))
        _ = hotkey
    }

    // MARK: - Escape

    /// **Escape is claimed while something it dismisses is on screen, and only then**: a press dismisses the topmost,
    /// and the last one out gives Escape back to the reader's app.
    @Test func escapeIsHeldOnlyWhileSomethingItDismissesIsShown() throws {
        let backend = FakeHotkeyBackend()
        let center = HotkeyCenter(backend: backend)
        final class Surfaces {
            var dismissed: [String] = []
            var entries: [String: EscapeStack.Entry] = [:]
        }
        let surfaces = Surfaces()
        #expect(!center.escape.isClaimed)
        for name in ["panel", "other"] {
            surfaces.entries[name] = center.escape.push {
                surfaces.dismissed.append(name)
                if let entry = surfaces.entries[name] { center.escape.pop(entry) }
            }
        }
        var dismissed: [String] { surfaces.dismissed }
        #expect(center.escape.isClaimed)
        #expect(backend.shortcuts == [EscapeStack.shortcut], "one claim, however many surfaces")
        #expect(center.route(press(1)) == noErr)
        #expect(dismissed == ["other"])
        #expect(center.escape.isClaimed)
        #expect(center.route(press(1)) == noErr)
        #expect(dismissed == ["other", "panel"])
        #expect(!center.escape.isClaimed)
        #expect(backend.unregistered == 1, "Escape was not given back")
    }

    /// Bare Escape: ⇧⎋ and ⌘⎋ stay with the app in front (Carbon matches modifiers exactly).
    @Test func escapeIsBare() {
        #expect(EscapeStack.shortcut == Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0))
    }
}

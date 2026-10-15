import Carbon.HIToolbox
import Foundation
import Testing
import XDictAnywhere

/// **The lookup shortcut's state machine** (plan-macos-v1 WI-8, done-when: "a rebinding persists, a clash is reported
/// and the old binding is restored on failure"). Moved from XiaolaiDict's `ShortcutRegistrar` and its settings-wiring
/// tests, its sentences left to the view layer.
@MainActor
struct ShortcutRegistrarTests {
    private let chosen = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey))

    private func registrar(_ backend: FakeHotkeyBackend, _ defaults: UserDefaults,
                           pressed: @escaping @MainActor () -> Void = {}) -> ShortcutRegistrar {
        ShortcutRegistrar(defaults: defaults, hotkeys: HotkeyCenter(backend: backend), onPress: pressed)
    }

    @Test func theSavedShortcutIsRegisteredAndAPressLooksUp() throws {
        let backend = FakeHotkeyBackend()
        let center = HotkeyCenter(backend: backend)
        var presses = 0
        let shortcut = ShortcutRegistrar(defaults: try ShortcutTests.scratchDefaults(), hotkeys: center) { presses += 1 }
        #expect(shortcut.registerSaved() == nil)
        #expect(shortcut.isRegistered)
        #expect(shortcut.current == .defaultLookUp)
        #expect(backend.shortcuts == [.defaultLookUp])
        #expect(shortcut.problem == nil)
        let id = try #require(backend.registered.last)
        #expect(center.route(id) == noErr)
        #expect(presses == 1)
    }

    /// **A rebinding persists**: registered at once, saved, and what a new registrar (the next launch) registers.
    @Test func aRebindingPersists() throws {
        let defaults = try ShortcutTests.scratchDefaults()
        let backend = FakeHotkeyBackend()
        let first = registrar(backend, defaults)
        first.registerSaved()
        #expect(first.choose(chosen) == nil)
        #expect(first.current == chosen)
        #expect(backend.shortcuts.last == chosen)
        #expect(ShortcutStore(defaults: defaults).load() == chosen)

        let relaunched = FakeHotkeyBackend()
        let second = registrar(relaunched, defaults)
        second.registerSaved()
        #expect(relaunched.shortcuts == [chosen], "the next launch registered \(relaunched.shortcuts)")
    }

    /// **A clash is reported and the old binding restored**: another app holds the new one, so the old one is
    /// registered again, still answers, and stays saved; the problem names both.
    @Test func aClashIsReportedAndTheOldBindingRestored() throws {
        let defaults = try ShortcutTests.scratchDefaults()
        let backend = FakeHotkeyBackend()
        backend.refused = [chosen]
        let shortcut = registrar(backend, defaults)
        shortcut.registerSaved()
        let refusal = shortcut.choose(chosen)
        #expect(refusal == .refused(chosen, .takenByAnotherApp, stillUsing: .defaultLookUp))
        #expect(shortcut.problem == refusal)
        #expect(shortcut.isRegistered)
        #expect(shortcut.current == .defaultLookUp)
        #expect(backend.shortcuts.last == .defaultLookUp, "the old binding was not registered again")
        #expect(ShortcutStore(defaults: defaults).load() == .defaultLookUp, "the refused one was saved")
    }

    /// **A rollback that also fails is not reported as a success**: no shortcut is registered, and the problem says so
    /// rather than naming one that no longer works.
    @Test func aRollbackThatFailsTooIsSaidToHaveFailed() throws {
        let backend = FakeHotkeyBackend()
        let shortcut = registrar(backend, try ShortcutTests.scratchDefaults())
        shortcut.registerSaved()
        backend.refused = [chosen, .defaultLookUp]
        #expect(shortcut.choose(chosen) == .refused(chosen, .takenByAnotherApp, stillUsing: nil))
        #expect(!shortcut.isRegistered)
    }

    /// A combination the standard commands or the system rely on is refused before anything is asked of Carbon, and the
    /// shortcut in use stays.
    @Test func aReservedCombinationIsRefusedAndTheOldOneKept() throws {
        let backend = FakeHotkeyBackend()
        let shortcut = registrar(backend, try ShortcutTests.scratchDefaults())
        shortcut.registerSaved()
        let copy = Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))
        #expect(shortcut.choose(copy, keyName: { $0 == UInt32(kVK_ANSI_C) ? "c" : nil }) == .reserved(copy))
        #expect(shortcut.choose(Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(shiftKey)))
                == .unusable(Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(shiftKey))))
        #expect(backend.shortcuts == [.defaultLookUp])
        #expect(shortcut.current == .defaultLookUp && shortcut.isRegistered)
    }

    /// The saved shortcut taken by another app at launch: nothing registered, and why.
    @Test func aSavedShortcutAnotherAppHoldsIsReported() throws {
        let backend = FakeHotkeyBackend()
        backend.refused = [.defaultLookUp]
        let shortcut = registrar(backend, try ShortcutTests.scratchDefaults())
        #expect(shortcut.registerSaved() == .unavailable(.defaultLookUp, .takenByAnotherApp))
        #expect(shortcut.problem == .unavailable(.defaultLookUp, .takenByAnotherApp))
        #expect(!shortcut.isRegistered)
    }

    /// **While the field in Settings is armed nothing is registered** — or the shortcut being replaced would fire
    /// instead of reaching the field — and every way recording ends puts it back, once.
    @Test func recordingStandsTheShortcutDownAndPutsItBack() throws {
        let backend = FakeHotkeyBackend()
        let shortcut = registrar(backend, try ShortcutTests.scratchDefaults())
        shortcut.registerSaved()
        shortcut.suspend(true)
        #expect(!shortcut.isRegistered && shortcut.isSuspended)
        #expect(shortcut.current == .defaultLookUp, "the field shows what is saved while nothing is registered")
        shortcut.suspend(false)
        shortcut.suspend(false)
        #expect(shortcut.isRegistered)
        #expect(backend.shortcuts == [.defaultLookUp, .defaultLookUp], "registered again exactly once")
    }

    /// Choosing the same shortcut again changes nothing.
    @Test func choosingTheSameShortcutIsNoChange() throws {
        let backend = FakeHotkeyBackend()
        let shortcut = registrar(backend, try ShortcutTests.scratchDefaults())
        shortcut.registerSaved()
        #expect(shortcut.choose(.defaultLookUp) == nil)
        #expect(backend.shortcuts == [.defaultLookUp])
    }
}

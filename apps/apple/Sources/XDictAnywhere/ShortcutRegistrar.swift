import Carbon.HIToolbox
import Foundation
import Observation
import XDictBase
import os

/// What went wrong with the lookup shortcut, **by kind**: the view layer words it (`AnywhereSentences`).
public enum ShortcutProblem: Hashable, Sendable {
    /// The saved shortcut could not be registered: nothing answers.
    case unavailable(Shortcut, RegistrationRefusal)
    /// The reader's choice was refused; `stillUsing` is the one put back, nil when that failed too.
    case refused(Shortcut, RegistrationRefusal, stillUsing: Shortcut?)
    /// A standard command or one of the system's: refused before anything was asked; the old one stays.
    case reserved(Shortcut)
    /// No ⌘, ⌃ or ⌥: it would fire while typing; the old one stays.
    case unusable(Shortcut)
    /// Registered, but not written to disk: it will not survive a relaunch.
    case notSaved(Shortcut)
}

/// **The lookup shortcut** (plan-macos-v1 WI-8; moved from XiaolaiDict's `ShortcutRegistrar`, its sentences left to the
/// view layer): what is registered, what the reader is choosing, and what went wrong. Three states that look like two —
/// registered; not registered because nothing claimed it; not registered *because the reader is recording a
/// replacement* — so suspension is recorded, never inferred, and **while suspended nothing registers** (audit
/// 2026-11-05 L15): a registration asked meanwhile waits for the recording's end, and a choice made meanwhile is taken
/// then. Every way a recording ends puts the hot key back (`suspend(false)` is idempotent); a refused choice puts the
/// old one back and **says so only if that worked**.
@Observable
@MainActor
public final class ShortcutRegistrar {
    @ObservationIgnored private let log = Logger(subsystem: XDictIdentity.app, category: "shortcut")
    @ObservationIgnored private let store: ShortcutStore
    @ObservationIgnored private let hotkeys: HotkeyCenter
    @ObservationIgnored private let onPress: @MainActor () -> Void

    /// Live, with the hot key registered or not; or suspended while the recorder is armed, with no hot key at all and
    /// the choice to take when it ends. One state, so a hot key cannot exist while suspended.
    private enum Standing {
        case live(Hotkey?)
        case suspended(pending: Shortcut?)
    }

    private var standing = Standing.live(nil)
    private var hotkey: Hotkey? {
        if case .live(let hotkey) = standing { hotkey } else { nil }
    }
    /// Nil when all is well; otherwise what to tell the reader.
    public private(set) var problem: ShortcutProblem?
    /// Whether the recorder in Settings is armed.
    public var isSuspended: Bool {
        if case .suspended = standing { true } else { false }
    }

    public init(defaults: UserDefaults, hotkeys: HotkeyCenter, onPress: @escaping @MainActor () -> Void) {
        store = ShortcutStore(defaults: defaults)
        self.hotkeys = hotkeys
        self.onPress = onPress
    }

    /// The shortcut registered, or — while nothing is — the one on disk.
    public var current: Shortcut { hotkey?.shortcut ?? store.load() }
    public var isRegistered: Bool { hotkey != nil }

    /// Registers what is on disk; the refusal, if any, is also `problem`. While suspended, nothing: the recording's end
    /// registers.
    @discardableResult
    public func registerSaved() -> ShortcutProblem? {
        guard !isSuspended else { return nil }
        let saved = store.load()
        if let refusal = register(saved) {
            problem = .unavailable(saved, refusal)
            return problem
        }
        problem = nil
        return nil
    }

    /// Only while live: every caller checks `isSuspended` first.
    private func register(_ shortcut: Shortcut) -> RegistrationRefusal? {
        standing = .live(nil)  // released first: registration is exclusive, and would collide with itself
        do {
            standing = .live(try hotkeys.register(shortcut) { [weak self] in self?.onPress() })
            return nil
        } catch {
            log.error("hotkey \(shortcut.label(), privacy: .public) unavailable: \(String(describing: error.reason), privacy: .public)")
            return error.reason
        }
    }

    /// Stands the hot key down while the recorder is armed — or pressing the shortcut in use would look a word up
    /// instead of reaching the field — and puts it back after, once.
    public func suspend(_ suspended: Bool) {
        switch (standing, suspended) {
        case (.live, true):
            standing = .suspended(pending: nil)
        case (.suspended(let pending), false):
            standing = .live(nil)
            if let pending {
                take(pending, previous: store.load())
            } else {
                registerSaved()
            }
        case (.live(nil), false):
            registerSaved()
        case (.live, false), (.suspended, true):
            break
        }
    }

    /// Takes the reader's new shortcut: refused by rule if reserved or unusable, else registered and saved if it held.
    /// Nil means it held (or is the one in use); otherwise the problem, also `problem`, and the old one left working
    /// where it can be.
    @discardableResult
    public func choose(_ chosen: Shortcut, keyName: (UInt32) -> String? = Shortcut.currentLayoutName) -> ShortcutProblem? {
        let previous = current
        guard chosen != previous || hotkey == nil else { return nil }
        if !chosen.isUsable { return refuse(.unusable(chosen)) }
        if chosen.isReserved(keyName: keyName) { return refuse(.reserved(chosen)) }
        // Refused by rule at once; registered only once the recorder is no longer armed.
        if isSuspended {
            standing = .suspended(pending: chosen)
            return nil
        }
        return take(chosen, previous: previous)
    }

    /// Registers and saves a choice the rules allowed, putting `previous` back if it is refused.
    @discardableResult
    private func take(_ chosen: Shortcut, previous: Shortcut) -> ShortcutProblem? {
        if let refusal = register(chosen) {
            let restored = register(previous) == nil
            return refuse(.refused(chosen, refusal, stillUsing: restored ? previous : nil))
        }
        do {
            try store.save(chosen)
            problem = nil
        } catch {
            log.error("shortcut not saved: \(String(describing: error), privacy: .public)")
            problem = .notSaved(chosen)
        }
        return problem
    }

    private func refuse(_ why: ShortcutProblem) -> ShortcutProblem {
        // A refusal by rule registers nothing and releases nothing; a refused registration put the old one back above.
        problem = why
        return why
    }
}

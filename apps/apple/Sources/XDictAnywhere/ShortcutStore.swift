import Carbon.HIToolbox
import Foundation

extension Shortcut {
    /// A combination as a key event reports it: its key code and which modifiers were held.
    public init(keyCode: UInt16, command: Bool, option: Bool, control: Bool, shift: Bool) {
        var modifiers = 0
        if command { modifiers |= cmdKey }
        if option { modifiers |= optionKey }
        if control { modifiers |= controlKey }
        if shift { modifiers |= shiftKey }
        self.init(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }
}

/// The reader's chosen shortcut, kept in user defaults (the app's own), so a rebinding survives a relaunch.
public struct ShortcutStore {
    public static let key = "lookUpShortcut"
    public let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The saved shortcut, or the default when none is saved — or what is saved is unusable.
    public func load() -> Shortcut {
        guard let data = defaults.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode(Shortcut.self, from: data), saved.isUsable
        else { return .defaultLookUp }
        return saved
    }

    public func save(_ shortcut: Shortcut) throws {
        defaults.set(try JSONEncoder().encode(shortcut), forKey: Self.key)
    }
}

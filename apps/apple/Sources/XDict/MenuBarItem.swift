import AppKit
import SwiftUI
import XDictAnywhere
import XDictBase
import XDictCapture
import XDictTokens
import XDictUI
import os

/// **The menu bar icon: a click opens the reading history, a right click (or a control click) opens the menu** (ported
/// from XiaolaiDict's `MenuBarItem`, plan-history-and-learning §4).
///
/// **`MenuBarExtra` cannot do this, and the reason is not a missing API to find.** Measured 2026-10-01 against the button
/// SwiftUI makes: `menu`, `target`, `action` and `cell.menu` are all nil, and its responder chain ends at
/// `NSStatusBarWindow` — SwiftUI drives the item privately, so there is nothing public to take over. So the item is the
/// app's own: `statusItem.menu` stays nil, which is what lets a click reach an action at all, and the menu is attached
/// for the length of one secondary click.
///
/// **The menu is rebuilt every time it opens**, which is why nothing here observes anything: the pause state and the
/// shortcut problem are read at the moment the reader asks to see them, so none of them can be stale.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    /// Where AppKit keeps this item's position: named, because the name it chooses for itself is positional (`Item-0`)
    /// and would be inherited by whatever item a later version created first.
    static let autosaveName = "XDictMenuBarItem"

    private let log = Logger(subsystem: XDictIdentity.app, category: "menubar")
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    /// The owned button's live frame in AppKit screen points: the drawer opens on the display it was clicked on.
    var screenFrame: CGRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.autosaveName = Self.autosaveName
        if let image = Self.icon {
            item.button?.image = image
        } else {
            // No image at all is still no reason to show nothing.
            item.button?.title = "XDict"
        }
        item.button?.setAccessibilityTitle(String(localized: "XDict", comment: "The menu bar icon, for VoiceOver"))
        // **No menu on the item**, which is what makes the action run at all: AppKit pops a status item's menu itself on
        // mouse-down and never calls the button's action.
        item.menu = nil
        item.button?.target = self
        item.button?.action = #selector(clicked)
        // **Up, not down**: `performClick` runs a menu tracking loop, and starting one from inside a mouse-down leaves the
        // button waiting for an up the loop has already taken.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let registrar = LookupAnywhere.shared.registrar
        item.button?.toolTip = Self.tooltip(shortcut: registrar.isRegistered
                                            ? registrar.current.label(keyName: Shortcut.currentLayoutName) : nil)
        offerBothSurfacesToAssistiveTechnology(on: item.button)
        menu.delegate = self
        log.notice("menu bar: left click opens the reading history, right click opens the menu")
    }

    /// The designer's 22 pt glyph (`Resources/MenuBarIcon.svg`, ported from XiaolaiDict with the app icon), marked as a
    /// template so the system draws it in the menu bar's own colour: only its alpha is read.
    private static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            Logger(subsystem: XDictIdentity.app, category: "menubar")
                .error("MenuBarIcon.svg is not in the bundle; the menu bar shows the app's name")
            return nil
        }
        image.isTemplate = true
        image.size = Tokens.Size.menuBarIcon
        return image
    }()

    /// The tooltip names both clicks as well as the shortcut: the menu sits behind a right click that nothing on screen
    /// announces, and the shortcut is otherwise only found in Settings.
    static func tooltip(shortcut: String?) -> String {
        guard let shortcut else {
            return String(localized: """
                XDict — click for Reading History, right-click for the menu. \
                No lookup shortcut is registered.
                """, comment: "The menu bar icon's tooltip when no lookup shortcut is registered")
        }
        return String(localized: """
            XDict — click for Reading History, right-click for the menu, \
            press \(shortcut) to look up the selection
            """, comment: "The menu bar icon's tooltip, naming both clicks and the registered lookup shortcut")
    }

    // MARK: - Clicks

    /// The routing XiaolaiDict measured to work: a secondary click attaches the menu for the length of that click, and
    /// anything else shows the history — **shows, never toggles**: a repeated click keeps it open, and `show` is a no-op
    /// when it is already there.
    @objc private func clicked() {
        guard StatusItemClick.isSecondary(NSApp.currentEvent) else {
            MenuBarActions.showHistory()
            return
        }
        showMenu()
    }

    /// Attached for this one showing only, so the next left click is ours again.
    private func showMenu() {
        guard let statusItem else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// The drawer opened or closed, by whatever route — a click, Escape, a click elsewhere, Review. An icon that looks
    /// the same open and shut gives the reader no answer to "did that work".
    func historyBecame(visible: Bool) {
        statusItem?.button?.highlight(visible)
    }

    /// **Both surfaces, by name, for a reader who has no right click.** VoiceOver's default press arrives as the button's
    /// action with no mouse event, so it could only ever show the history; the menu is opened a turn later, because an
    /// action that runs a menu's tracking loop does not return to the caller that asked until the menu closes.
    private func offerBothSurfacesToAssistiveTechnology(on button: NSStatusBarButton?) {
        button?.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(
                name: String(localized: "Show Menu", comment: "VoiceOver action on the menu bar icon")
            ) { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.showMenu() }
                }
                return true
            },
            NSAccessibilityCustomAction(
                name: String(localized: "Show Reading History", comment: "VoiceOver action on the menu bar icon")
            ) {
                MainActor.assumeIsolated { MenuBarActions.showHistory() }
                return true
            },
        ])
    }

    // MARK: - The menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let registrar = LookupAnywhere.shared.registrar
        // The shortcut's problem at the top when there is one: the menu is where a reader looks when it does nothing.
        if let problem = registrar.problem {
            menu.addItem(Self.disabled(String(localized: AnywhereSentences.problem(problem))))
            menu.addItem(.separator())
        }
        let lookUp = NSMenuItem(title: String(localized: "Look Up Selection"), action: #selector(lookUpSelection),
                                keyEquivalent: "")
        if registrar.isRegistered, let key = ShortcutDisplay.keyEquivalent(registrar.current) {
            lookUp.keyEquivalent = String(key.key)  // placement: menubar-item
            lookUp.keyEquivalentModifierMask = Self.flags(key.modifiers)
        }
        lookUp.target = self
        menu.addItem(lookUp)
        menu.addItem(Self.item(String(localized: "Open XDict"), #selector(openMain), target: self))

        menu.addItem(.separator())
        // **Reading history is not here**: the icon's own click opens it, and an item that repeats the click that opened
        // the menu is a line the reader reads past. **Nor an ellipsis on Review**: it opens a window and asks for nothing
        // more (XiaolaiDict's audit M7).
        menu.addItem(Self.item(String(localized: "Review"), #selector(showReview), target: self))
        menu.addItem(Self.item(String(localized: "Dictionaries…"), #selector(showDictionaries), target: self))

        menu.addItem(.separator())
        addPauseGroup(to: menu)

        menu.addItem(.separator())
        let settings = Self.item(String(localized: "Settings…"), #selector(showSettings), target: self)
        settings.keyEquivalent = ","  // placement: menubar-item
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(Self.item(String(localized: "Quit XDict"), #selector(quit), target: self))
    }

    /// The pause group, from the reader's setting and the control's one pause; with hover off, said rather than left out.
    private func addPauseGroup(to menu: NSMenu) {
        let hover = LookupAnywhere.shared.hover
        let now = Date.now
        for entry in HoverPauseMenu.entries(for: hover, now: now) {
            switch entry {
            case .pause:
                let pause = NSMenuItem(title: HoverSentences.pauseEntry(entry, now: now), action: nil, keyEquivalent: "")
                let lengths = NSMenu()
                for length in HoverPause.durations {
                    let item = NSMenuItem(title: String(localized: HoverSentences.pauseLength(length)),
                                          action: #selector(pauseHover(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = length
                    lengths.addItem(item)
                }
                pause.submenu = lengths
                menu.addItem(pause)
            case .resume:
                menu.addItem(Self.item(HoverSentences.pauseEntry(entry, now: now), #selector(resumeHover), target: self))
            case .resumesAt, .hoverIsOff:
                menu.addItem(Self.disabled(HoverSentences.pauseEntry(entry, now: now)))
            }
        }
    }

    /// The shortcut's modifiers as AppKit's own: `ShortcutDisplay` speaks SwiftUI's, because a SwiftUI menu drew it before
    /// the item became the app's.
    static func flags(_ modifiers: SwiftUI.EventModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    private static func item(_ title: String, _ action: Selector, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func lookUpSelection() { LookupAnywhere.shared.lookUpFromMenu() }
    @objc private func openMain() { MenuBarActions.openMain() }
    @objc private func showReview() { MenuBarActions.openReview() }
    @objc private func showDictionaries() { MenuBarActions.showDictionaries() }
    @objc private func showSettings() { MenuBarActions.openSettings() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func resumeHover() { LookupAnywhere.shared.hover.resume() }

    @objc private func pauseHover(_ sender: NSMenuItem) {
        guard let length = sender.representedObject as? Duration else { return }
        LookupAnywhere.shared.hover.pause(for: length)
    }
}

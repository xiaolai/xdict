import AppKit
import SwiftUI
import XDictSearch

/// **The scope bar** (Apple parity P6, P8, P42): under the toolbar, 36 pt high across the pane, "All" then each enabled
/// dictionary by name as AppKit's accessory-bar toggles — text only, the chosen one on a grey capsule — read by
/// VoiceOver as one radio group; what does not fit goes to a » menu ("more dictionaries"). A 1 pt rule below it.
struct ScopeBar: NSViewRepresentable {
    let state: SearchWindowState

    func makeNSView(context: Context) -> ScopeBarView {
        let bar = ScopeBarView()
        bar.onChoose = { [state] scope in state.model.setScope(scope) }
        return bar
    }

    func updateNSView(_ bar: ScopeBarView, context: Context) {
        let model = state.model
        let enabled = model.known.filter(\.enabled)
        bar.update(items: [ScopeBarView.Item(scope: .all, title: String(localized: "All"), enabled: true)]
                   + enabled.map { ScopeBarView.Item(scope: .one($0.id), title: $0.name, enabled: $0.handle != nil) },
                   selected: model.scope)
    }
}

final class ScopeBarView: NSView {
    struct Item: Equatable {
        let scope: SearchScope
        let title: String
        let enabled: Bool
    }

    var onChoose: ((SearchScope) -> Void)?
    private var items: [Item] = []
    private var selected: SearchScope = .all
    private let group = ScopeRadioGroup()
    private var buttons: [ScopeButton] = []
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private let rule = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(group)
        more.bezelStyle = .accessoryBarAction
        more.isBordered = false
        (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        more.setAccessibilityLabel(String(localized: "more dictionaries"))
        more.toolTip = String(localized: "Show more dictionaries")
        more.setAccessibilityIdentifier("scope.more")
        addSubview(more)
        rule.boxType = .separator
        addSubview(rule)
        group.setAccessibilityIdentifier("scope")
        group.setAccessibilityLabel(String(localized: "Dictionaries"))
        // The bar itself, a plain group: where the entry below it starts is measured from its bottom.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("scope.bar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: ScopeBarLayout.height) }

    func update(items: [Item], selected: SearchScope) {
        guard items != self.items || selected != self.selected else { return }
        if items != self.items {
            self.items = items
            buttons.forEach { $0.removeFromSuperview() }
            buttons = items.enumerated().map { index, item in
                let button = ScopeButton(title: item.title, target: self, action: #selector(chose(_:)))
                button.tag = index
                button.isEnabled = item.enabled
                group.addSubview(button)
                return button
            }
        }
        self.selected = selected
        for (button, item) in zip(buttons, items) { button.state = item.scope == selected ? .on : .off }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        rule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        let widths = buttons.map { ceil($0.fittingSize.width) }
        let shown = ScopeBarLayout.shown(widths: widths, available: bounds.width)
        var x: CGFloat = 0
        let y = ((bounds.height - ScopeBarLayout.buttonHeight) / 2).rounded()
        for (index, button) in buttons.enumerated() {
            button.isHidden = index >= shown
            guard index < shown else { continue }
            button.frame = NSRect(x: x, y: 0, width: widths[index], height: ScopeBarLayout.buttonHeight)
            x += widths[index]
        }
        group.frame = NSRect(x: ScopeBarLayout.leading, y: y, width: x, height: ScopeBarLayout.buttonHeight)
        more.isHidden = shown >= buttons.count
        more.frame = NSRect(x: bounds.width - ScopeBarLayout.moreWidth, y: 0, width: ScopeBarLayout.moreWidth,
                            height: bounds.height)
        rebuildMore(from: shown)
    }

    private func rebuildMore(from shown: Int) {
        let menu = NSMenu()
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "chevron.right.2", accessibilityDescription: nil)
        menu.addItem(title)
        for (index, item) in items.enumerated() where index >= shown {
            let entry = NSMenuItem(title: item.title, action: #selector(choseMore(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = item.scope == selected ? .on : .off
            entry.isEnabled = item.enabled
            menu.addItem(entry)
        }
        more.menu = menu
    }

    @objc private func chose(_ sender: NSButton) { choose(sender.tag) }
    @objc private func choseMore(_ sender: NSMenuItem) { choose(sender.tag) }

    private func choose(_ index: Int) {
        guard items.indices.contains(index) else { return }
        // A toggle clicked again stays on: a scope is always chosen.
        for (offset, button) in buttons.enumerated() { button.state = offset == index ? .on : .off }
        onChoose?(items[index].scope)
    }
}

/// The buttons' group, read by VoiceOver as Apple's scope bar is: one radio group.
final class ScopeRadioGroup: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }
}

/// One scope: an accessory-bar toggle, text only, read as a radio button named by its title (`scope.option`), its value
/// 1 when it is the chosen scope and 0 otherwise, as an AppKit radio button reads.
final class ScopeButton: NSButton {
    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        setButtonType(.pushOnPushOff)
        bezelStyle = .accessoryBar
        showsBorderOnlyWhileMouseInside = true
        font = .systemFont(ofSize: NSFont.systemFontSize)
        controlSize = .regular
        setAccessibilityIdentifier("scope.option")
        setAccessibilityLabel(title)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .toggle }
    override func accessibilityValue() -> Any? { NSNumber(value: state == .on ? 1 : 0) }
}

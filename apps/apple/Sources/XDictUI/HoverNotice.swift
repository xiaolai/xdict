import AppKit
import SwiftUI
import XDictTokens

/// **Where the brief hover notice sits** (owner's report, 2026-10-19: a hover that read nothing showed nothing). Screen
/// points, y up. Above and to the right of the pointer, clear of it by `Tokens.Inset.hoverNoticeOffset`; on the other side
/// of the pointer, on either axis, where that would leave the visible frame. **Never over the pointer**, where it would
/// hide the word being read; hover looks through it either way, as it takes no click (`HoverReader.passesClicksThrough`).
enum HoverNoticePlacement {
    /// How far clear of the pointer, on both axes.
    static let offset = Tokens.Inset.hoverNoticeOffset

    static func frame(size: CGSize, pointer: CGPoint, visible: CGRect) -> CGRect {
        var x = pointer.x + offset
        if x + size.width > visible.maxX { x = pointer.x - offset - size.width }
        var y = pointer.y + offset
        if y + size.height > visible.maxY { y = pointer.y - offset - size.height }
        return CGRect(x: max(visible.minX, x), y: max(visible.minY, y), width: size.width, height: size.height)
    }
}

/// **The brief line hover shows by the pointer**: a borderless panel that never activates XDict, never takes a click
/// (`ignoresMouseEvents`) and goes on its own after `shownFor`, ordered out so the compositor no longer lists it. One at a
/// time: a new line replaces the one showing. It carries a kind's sentence only, never a word or a sentence read.
@MainActor
public final class HoverNoticeHUD {
    /// How long a line stays: a duration, not a design value.
    static let shownFor: Duration = .milliseconds(1_600)
    private(set) var panel: NSPanel?
    private var hiding: Task<Void, Never>?

    public init() {}

    /// Shows `line` by `pointer` (screen points, y up, as `NSEvent.mouseLocation`).
    public func show(_ line: String, near pointer: CGPoint) {
        let host = NSHostingView(rootView: HoverNoticeLine(line: line))
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = host
        panel.setFrame(HoverNoticePlacement.frame(size: size, pointer: pointer, visible: visible), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        hiding?.cancel()
        hiding = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.shownFor)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    /// Click-through (`ignoresMouseEvents`: hover looks through a window of XDict's that takes no click), non-activating,
    /// never key or main (`HoverNoticePanelTests`).
    static func makePanel() -> NSPanel {
        let panel = HoverNoticePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                                     defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.setAccessibilityIdentifier("hover.briefNotice")
        return panel
    }
}

/// The notice's panel: it can be neither key nor main, whatever it is asked — and counts being asked, so a test sees a
/// `makeKeyAndOrderFront` that macOS would quietly refuse.
final class HoverNoticePanel: NSPanel {
    private(set) var askedToBecomeKey = 0
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        askedToBecomeKey += 1
        super.makeKeyAndOrderFront(sender)
    }

    override func makeKey() {
        askedToBecomeKey += 1
        super.makeKey()
    }
}

/// The line itself: callout text on the system's regular material, in a capsule.
private struct HoverNoticeLine: View {
    let line: String

    var body: some View {
        Text(verbatim: line)
            .font(Tokens.TextRole.callout.font)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, Tokens.Space.m)
            .padding(.vertical, Tokens.Space.s)
            .background(.regularMaterial, in: Capsule())
            .accessibilityAddTraits(.updatesFrequently)
    }
}

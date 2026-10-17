import AppKit
import SwiftUI

/// **The lookup panel's title-bar buttons** (UI review P-01): a panel is neither minimized nor zoomed, so it shows only
/// its close button (Escape and a click away close it too).
public enum PanelChrome {
    public static let hidden: [NSWindow.ButtonType] = [.miniaturizeButton, .zoomButton]

    @MainActor
    public static func apply(to window: NSWindow) {
        for kind in hidden { window.standardWindowButton(kind)?.isHidden = true }
    }
}

/// **One size rule for every Settings pane and the setup board** (UI review X2, S-01, U-01): a grouped form as tall as
/// its rows, at one width, so the window fits the pane — none clipped, none swimming in white space.
struct SettingsPane: ViewModifier {
    var width: CGFloat = 480

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width)
    }
}

extension View {
    func settingsPane(width: CGFloat = 480) -> some View { modifier(SettingsPane(width: width)) }
}

/// The menu-bar item's one preference (UI review S-04): shown unless the reader hides it.
public enum MenuBarItem {
    public static let shownKey = "menuBarItem.shown"
}

/// **Add Dictionaries… asked from anywhere** (UI review A-04, M-10, U-02): File ▸ Add Dictionaries…, the main window's
/// empty state and the setup board open the Library with its open panel up. The request waits until a Library view is
/// there to take it.
@MainActor
@Observable
public final class LibraryRequests {
    public static let shared = LibraryRequests()
    public private(set) var importWanted = false

    public func requestImport() { importWanted = true }

    /// Taken once, by the Library view that shows the open panel.
    func takeImport() -> Bool {
        defer { importWanted = false }
        return importWanted
    }
}

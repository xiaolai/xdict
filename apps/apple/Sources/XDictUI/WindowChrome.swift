import AppKit
import SwiftUI

/// **One size rule for every Settings pane and the setup board** (UI review X2, S-01, U-01): a grouped form as tall as
/// its rows, at one width (Apple's Settings window, 600 pt: parity P39), so the window fits the pane — none clipped.
struct SettingsPane: ViewModifier {
    var width: CGFloat = SettingsDictionaries.paneWidth

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width)
    }
}

extension View {
    func settingsPane(width: CGFloat = SettingsDictionaries.paneWidth) -> some View { modifier(SettingsPane(width: width)) }
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

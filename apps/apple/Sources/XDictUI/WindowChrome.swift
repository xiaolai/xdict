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

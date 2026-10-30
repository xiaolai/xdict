import SwiftUI
import XDictAnywhere
import XDictTokens

/// **Lookup, a pane of its own** (owner's settings audit, 2026-10-30: the shortcut, hover with its permission and its
/// exclusions, and the popup's appearance were four sections of General, and the popup's dictionary list was in a third
/// pane — "how looking up behaves" had no one place). Three sections: **Shortcut** (the selection's key and the answer
/// pane's, side by side, so a clash is visible where it is made), **Hover** (`HoverSettings`: the switch, the key and the
/// gesture, the writing systems, Screen Recording, the apps never read), and **Popup** (its shade and its background).
public struct LookupSettings: View {
    private let registrar: ShortcutRegistrar
    private let hover: HoverControl
    @AppStorage(PanelAppearance.shadeKey) private var shade: PanelAppearance.Shade = .system
    @AppStorage(PanelAppearance.solidityKey) private var solidity = 0.0
    @AppStorage(MeaningPanePreferences.shortcutKey) private var paneShortcutKey = MeaningPanePreferences.defaultShortcutKey
    @AppStorage(MeaningPanePreferences.shortcutModifiersKey)
    private var paneShortcutModifiers = MeaningPanePreferences.defaultShortcutModifiers
    /// Why the last combination was refused, said under the row; cleared when one is taken.
    @State private var shortcutRejection: MeaningPanePreferences.ShortcutRejection?

    public init(registrar: ShortcutRegistrar, hover: HoverControl) {
        self.registrar = registrar
        self.hover = hover
    }

    public var body: some View {
        Form {
            Section {
                ShortcutSettings(registrar: registrar)
                LabeledContent {
                    PaneShortcutRecorder(key: $paneShortcutKey, modifiers: $paneShortcutModifiers,
                                         suspend: { registrar.suspend($0) }, rejection: $shortcutRejection)
                } label: {
                    Text("Show or hide the answer pane")
                    Text("The keys that show or hide the pane beside the window.")
                }
                if let shortcutRejection {
                    // A combination XDict cannot take says why (HIG: a control that refuses explains itself).
                    Text(verbatim: MeaningPanePreferences.sentence(shortcutRejection))
                        .foregroundStyle(Tokens.Tint.red.color)
                        .accessibilityIdentifier("meaning-pane-shortcut.problem")
                }
            } header: {
                Text("Shortcut")
            }
            .settingsAnchor(.lookupShortcut)
            Section { HoverSettings(hover: hover) } header: { Text("Hover") }
                .settingsAnchor(.hover)
            Section {
                Picker(selection: $shade) {
                    Text("Follow System").tag(PanelAppearance.Shade.system)
                    Text("Light").tag(PanelAppearance.Shade.light)
                    Text("Dark").tag(PanelAppearance.Shade.dark)
                } label: {
                    Text("Shade")
                    Text("The popup's shade, apart from the rest of XDict.")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("panel-shade")
                // The slider's own label is the row's, as a picker's is: wrapped in a LabeledContent naming it again, the
                // form drew "Background" twice, the second after Solid (UI tour, 2026-10-19).
                Slider(value: $solidity, in: 0...1) {
                    Text("Background")
                } minimumValueLabel: {
                    Text("Glass")
                } maximumValueLabel: {
                    Text("Solid")
                }
                .accessibilityIdentifier("panel-solidity")
            } header: {
                Text("Popup")
            }
            .settingsAnchor(.popupAppearance)
        }
        .settingsPane()
    }
}

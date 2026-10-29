import SwiftUI
import XDictAnywhere
import XDictTokens

/// **General, in Settings** (⌘,; plan-macos-v1 WI-9, ADR-0012 d.1): launch at login, with what the system says of it, the
/// language of XDict's own words, the lookup shortcut (`ShortcutSettings`, once the Lookup pane), hover (`HoverSettings`,
/// plan-capture WI-3). The setup board is the sidebar's own pane (ADR-0012, amended 2026-10-20), so no row here points
/// at it; the accent and speech are under Reading & Speech, the dictionaries' order and languages under Dictionaries.
public struct GeneralSettings: View {
    @Bindable private var login: LaunchAtLogin
    private let defaults: UserDefaults
    private let domain: String
    @State private var language: InterfaceLanguage
    @AppStorage(PanelAppearance.shadeKey) private var shade: PanelAppearance.Shade = .system
    @AppStorage(PanelAppearance.solidityKey) private var solidity = 0.0
    /// **The reader's Dock icon choice** (owner, 2026-10-27), off for a reader who never chose: the app delegate reads the
    /// same key at launch, and this row applies a change at once (`DockVisibility`).
    @AppStorage(DockVisibility.key) private var showsInDock = false
    /// The answer pane's own options (owner, 2026-10-24): its gap from the window, its width, its opening time and the
    /// keys that toggle it.
    @AppStorage(MeaningPanePreferences.gapKey) private var paneGap = MeaningPanePreferences.defaultGap
    @AppStorage(MeaningPanePreferences.widthKey) private var paneWidth = MeaningPanePreferences.defaultWidth
    @AppStorage(MeaningPanePreferences.animationKey) private var paneAnimation = MeaningPanePreferences.defaultAnimation
    @AppStorage(MeaningPanePreferences.shortcutKey) private var paneShortcutKey = MeaningPanePreferences.defaultShortcutKey
    @AppStorage(MeaningPanePreferences.shortcutModifiersKey)
    private var paneShortcutModifiers = MeaningPanePreferences.defaultShortcutModifiers
    /// Why the last combination was refused, said under the row; cleared when one is taken.
    @State private var shortcutRejection: MeaningPanePreferences.ShortcutRejection?
    private let registrar: ShortcutRegistrar
    private let hover: HoverControl


    public init(login: LaunchAtLogin, defaults: UserDefaults, domain: String, registrar: ShortcutRegistrar,
                hover: HoverControl) {
        self.login = login
        self.registrar = registrar
        self.hover = hover
        self.defaults = defaults
        self.domain = domain
        _language = State(initialValue: InterfaceLanguage.current(in: defaults, domain: domain))
    }

    public var body: some View {
        // **Named groups, short captions** (UI28, UI29): each section says what it holds, as System Settings' panes do.
        Form {
            Section {
                Toggle(isOn: Binding(get: { login.isOn }, set: { login.set($0) })) {
                    Text("Open XDict when you log in")
                    Text(LaunchAtLogin.sentence(login.status))
                }
                .accessibilityLabel(Text("Open XDict when you log in"))
                .accessibilityIdentifier("launch-at-login")
                if login.needsApproval {
                    LabeledContent {
                        Button { login.openLoginItems() } label: { Text("Open Login Items Settings…") }  // placement: form-row
                            .accessibilityIdentifier("launch-at-login.approve")
                    } label: {
                        Text("Allow XDict in Login Items")
                    }
                }
                Toggle(isOn: $showsInDock) {
                    Text("Show XDict in the Dock")
                    Text("Off, the Dock icon comes with a dictionary window and goes when the last one closes; with no window XDict waits in the menu bar, the shortcut, the Service and hover with it. Quit it from that icon.")
                }
                .accessibilityIdentifier("show-in-dock")
                .onChange(of: showsInDock) { DockPresence.shared.apply() }
                if let failure = login.failure {
                    // XDict's own sentence; the system's reason (already in the reader's language) beneath it.
                    VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                        Text("The system did not change whether XDict opens when you log in.")
                        Text(verbatim: failure).font(.caption)
                    }
                    .foregroundStyle(Tokens.Tint.red.color)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("launch-at-login.failure")
                }
            } header: {
                Text("Startup")
            }
            .settingsAnchor(.startup)
            Section {
                Picker(selection: $language) {
                    ForEach(InterfaceLanguage.allCases) { choice in
                        Text(choice.name).tag(choice)
                    }
                } label: {
                    Text("Language")
                    Text("XDict’s own words, not the dictionaries’. Applies when XDict next opens.")
                }
                .accessibilityIdentifier("interface-language")
                .onChange(of: language) { _, chosen in chosen.apply(to: defaults) }
            } header: {
                Text("Language")
            }
            .settingsAnchor(.interfaceLanguage)
            Section { ShortcutSettings(registrar: registrar) } header: { Text("Lookup Shortcut") }
                .settingsAnchor(.lookupShortcut)
            Section { HoverSettings(hover: hover) } header: { Text("Hover") }
                .settingsAnchor(.hover)
            Section {
                Picker(selection: $shade) {
                    Text("Follow System").tag(PanelAppearance.Shade.system)
                    Text("Light").tag(PanelAppearance.Shade.light)
                    Text("Dark").tag(PanelAppearance.Shade.dark)
                } label: {
                    Text("Lookup popup")
                    Text("Its shade, apart from the rest of XDict.")
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
                Text("Lookup Popup")
            }
            .settingsAnchor(.popupAppearance)
            Section {
                Slider(value: $paneGap, in: MeaningPanePreferences.gapRange) {
                    Text("Gap beside the answer pane")
                    Text("The air between XDict’s window and the pane that opens beside it.")
                } minimumValueLabel: {
                    Text(verbatim: "\(Int(MeaningPanePreferences.gapRange.lowerBound))")
                } maximumValueLabel: {
                    Text(verbatim: "\(Int(MeaningPanePreferences.gapRange.upperBound))")
                }
                .accessibilityIdentifier("meaning-pane-gap")
                Slider(value: $paneWidth, in: MeaningPanePreferences.widthRange) {
                    Text("Width")
                    Text("How wide the pane opens beside the window.")
                } minimumValueLabel: {
                    Text(verbatim: "\(Int(MeaningPanePreferences.widthRange.lowerBound))")
                } maximumValueLabel: {
                    Text(verbatim: "\(Int(MeaningPanePreferences.widthRange.upperBound))")
                }
                .accessibilityIdentifier("meaning-pane-width")
                Slider(value: $paneAnimation, in: MeaningPanePreferences.animationRange, step: 0.05) {
                    Text("Opening")
                    Text("How long the pane takes to slide out. Off shows it at once.")
                } minimumValueLabel: {
                    Text("Off")
                } maximumValueLabel: {
                    Text(verbatim: "\(MeaningPanePreferences.animationRange.upperBound) s")
                }
                .accessibilityIdentifier("meaning-pane-animation")
                LabeledContent {
                    PaneShortcutRecorder(key: $paneShortcutKey, modifiers: $paneShortcutModifiers,
                                         suspend: { registrar.suspend($0) }, rejection: $shortcutRejection)
                } label: {
                    Text("Toggle the pane")
                    Text("The keys that show or hide the answer pane.")
                }
                if let shortcutRejection {
                    // A combination XDict cannot take says why (HIG: a control that refuses explains itself).
                    Text(verbatim: MeaningPanePreferences.sentence(shortcutRejection))
                        .foregroundStyle(Tokens.Tint.red.color)
                        .accessibilityIdentifier("meaning-pane-shortcut.problem")
                }
            } header: {
                Text("Answer Pane")
            }
            .settingsAnchor(.meaningPaneGap)
        }
        .settingsPane()
        .onAppear { login.refresh() }
        // The reader may have been to Login Items and back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }
}

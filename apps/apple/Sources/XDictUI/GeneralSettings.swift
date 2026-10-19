import SwiftUI
import XDictAnywhere
import XDictTokens

/// **General, in Settings** (⌘,; plan-macos-v1 WI-9, ADR-0012 d.1): launch at login, with what the system says of it, the
/// language of XDict's own words, the lookup shortcut (`ShortcutSettings`, once the Lookup pane), hover (`HoverSettings`,
/// plan-capture WI-3) and Show Setup…. The
/// accent and speech are under Reading & Speech, the dictionaries' order and languages under Dictionaries.
public struct GeneralSettings: View {
    @Bindable private var login: LaunchAtLogin
    private let defaults: UserDefaults
    private let domain: String
    @State private var language: InterfaceLanguage
    @AppStorage(PanelAppearance.shadeKey) private var shade: PanelAppearance.Shade = .system
    @AppStorage(PanelAppearance.solidityKey) private var solidity = 0.0
    /// The app delegate reads the same key of the same suite (`MenuBarResidence`); on for a reader who never chose.
    @AppStorage(MenuBarResidence.key) private var keepsRunning = true
    private let registrar: ShortcutRegistrar
    private let hover: HoverControl
    private let openSetup: () -> Void

    public init(login: LaunchAtLogin, defaults: UserDefaults, domain: String, registrar: ShortcutRegistrar,
                hover: HoverControl, openSetup: @escaping () -> Void) {
        self.login = login
        self.registrar = registrar
        self.hover = hover
        self.defaults = defaults
        self.domain = domain
        self.openSetup = openSetup
        _language = State(initialValue: InterfaceLanguage.current(in: defaults, domain: domain))
    }

    public var body: some View {
        Form {
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
            Toggle(isOn: $keepsRunning) {
                Text("Keep XDict in the menu bar")
                Text("With every window closed, XDict stays running: the shortcut, the Service and hover keep working. Off, XDict quits with its last window.")
            }
            .accessibilityIdentifier("keep-in-menu-bar")
            if let failure = login.failure {
                // XDict's own sentence; the system's reason (already in the reader's language) beneath it.
                VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                    Text("The system did not change whether XDict opens when you log in.")
                    Text(verbatim: failure).font(.caption)
                }
                .foregroundStyle(.red)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("launch-at-login.failure")
            }
            Picker(selection: $language) {
                ForEach(InterfaceLanguage.allCases) { choice in
                    Text(choice.name).tag(choice)
                }
            } label: {
                Text("Language")
                Text("XDict's own words; dictionaries are never translated. Takes effect when XDict next opens.")
            }
            .accessibilityIdentifier("interface-language")
            .onChange(of: language) { _, chosen in chosen.apply(to: defaults) }
            Section { ShortcutSettings(registrar: registrar) }
            Section { HoverSettings(hover: hover) }
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
            }
            Section {
                LabeledContent {
                    Button { openSetup() } label: { Text("Show Setup…") }  // placement: form-row
                        .accessibilityIdentifier("show-setup")
                } label: {
                    Text("Setup")
                }
            }
        }
        .settingsPane()
        .onAppear { login.refresh() }
        // The reader may have been to Login Items and back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }
}

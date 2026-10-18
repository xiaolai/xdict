import SwiftUI
import XDictAnywhere
import XDictTokens

/// **General, in Settings** (⌘,; plan-macos-v1 WI-9, ADR-0012 d.1): launch at login, with what the system says of it, the
/// language of XDict's own words, the lookup shortcut (`ShortcutSettings`, once the Lookup pane) and Show Setup…. The
/// accent and speech are under Reading & Speech, the dictionaries' order and languages under Dictionaries.
public struct GeneralSettings: View {
    @Bindable private var login: LaunchAtLogin
    private let defaults: UserDefaults
    private let domain: String
    @State private var language: InterfaceLanguage
    private let registrar: ShortcutRegistrar
    private let openSetup: () -> Void

    public init(login: LaunchAtLogin, defaults: UserDefaults, domain: String, registrar: ShortcutRegistrar,
                openSetup: @escaping () -> Void) {
        self.login = login
        self.registrar = registrar
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
            Section {
                LabeledContent {
                    Button { openSetup() } label: { Text("Show Setup…") }
                        .accessibilityIdentifier("show-setup")
                } label: {
                    Text("Setup")
                }
            }
        }
        .settingsPane()
        .onAppear { login.refresh() }
    }
}

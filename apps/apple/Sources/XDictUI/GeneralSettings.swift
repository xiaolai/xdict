import SwiftUI

/// **General, in Settings** (⌘,; plan-macos-v1 WI-9): launch at login, with what the system says of it, and the language
/// of XDict's own words. The accent is under Reading, the shortcut under Lookup, the dictionaries' order and languages
/// under Dictionaries (the library's own list, WI-5).
public struct GeneralSettings: View {
    @Bindable private var login: LaunchAtLogin
    private let defaults: UserDefaults
    private let domain: String
    @State private var language: InterfaceLanguage
    private let openSetup: () -> Void
    /// The menu-bar item, which the reader may hide (UI review S-04).
    @AppStorage(MenuBarItem.shownKey) private var showsMenuBarItem = true

    public init(login: LaunchAtLogin, defaults: UserDefaults, domain: String, openSetup: @escaping () -> Void) {
        self.login = login
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
                VStack(alignment: .leading, spacing: 2) {
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
            Toggle(isOn: $showsMenuBarItem) {
                Text("Show XDict in the menu bar")
                Text("Look Up Selection, the Library and Settings, from the menu bar.")
            }
            .accessibilityLabel(Text("Show XDict in the menu bar"))
            .accessibilityIdentifier("menu-bar-item")
            LabeledContent {
                Button { openSetup() } label: { Text("Show Setup…") }
                    .accessibilityIdentifier("show-setup")
            } label: {
                Text("Setup")
            }
        }
        .settingsPane()
        .onAppear { login.refresh() }
    }
}

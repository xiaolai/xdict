import SwiftUI
import XDictAnywhere
import XDictCapture
import XDictTokens

/// **General, in Settings** (⌘,; plan-macos-v1 WI-9; the owner's settings audit of 2026-10-30 gave the lookup surface its
/// own pane): what the app does around the reading — open at login with what the system says of it, the Dock icon, the
/// language of XDict's own words, and the diagnostics log a reader can hand back. **How looking up behaves is Lookup's**
/// (the shortcut, hover, the popup's appearance); the reading is Reading's and Speech's; the dictionaries' order and
/// languages are Dictionaries'. The setup board is the sidebar's own pane (ADR-0012, amended 2026-10-20).
public struct GeneralSettings: View {
    @Bindable private var login: LaunchAtLogin
    private let defaults: UserDefaults
    private let domain: String
    @State private var language: InterfaceLanguage
    /// **The reader's Dock icon choice** (owner, 2026-10-27), off for a reader who never chose: the app delegate reads the
    /// same key at launch, and this row applies a change at once (`DockVisibility`).
    @AppStorage(DockVisibility.key) private var showsInDock = false

    /// The library and hover, for the diagnostics export's header — how many dictionaries and enabled, and hover's own
    /// state — never for a setting of this pane, which is Lookup's (owner's audit, 2026-10-30). Nil where a host has none.
    private let library: (any DiagnosticsLibrary)?
    private let hover: HoverControl?
    /// The reader's words in their own diagnostics log (owner, 2026-10-29): off, and the log says how much text there was
    /// without saying what it was.
    @AppStorage(Diagnostics.includeTextKey) private var includeWordsInDiagnostics = false
    /// Why the last save failed, said in an alert that offers to try again; nil after a save or a cancellation.
    @State private var diagnosticsFailure: String?

    public init(login: LaunchAtLogin, defaults: UserDefaults, domain: String,
                hover: HoverControl? = nil, library: (any DiagnosticsLibrary)? = nil) {
        self.login = login
        self.hover = hover
        self.library = library
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
                Toggle(isOn: $showsInDock) {
                    Text("Show XDict in the Dock")
                    Text("Off, the Dock icon comes with a dictionary window and goes when the last one closes; with no window XDict waits in the menu bar, the shortcut, the Service and hover with it. Quit it from that icon.")
                }
                .accessibilityIdentifier("show-in-dock")
                .onChange(of: showsInDock) { DockPresence.shared.apply() }
            } header: {
                Text("Dock")
            }
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
            Section {
                Button {  // placement: form-row
                    saveDiagnostics()
                } label: {
                    Text("Save Diagnostics…")
                }
                .accessibilityIdentifier("save-diagnostics")
                Toggle(isOn: $includeWordsInDiagnostics) {
                    Text("Include the words I look up")
                    Text("Off, the log says how long a word was, never what it was. It never leaves this Mac unless you save it.")
                }
                .accessibilityIdentifier("diagnostics-include-words")
            } header: {
                Text("Diagnostics")
            }
            .settingsAnchor(.diagnostics)
        }
        .settingsPane()
        .onAppear { login.refresh() }
        // The reader may have been to Login Items and back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
        // **A save that fails is answered here** (audit 2026-10-29 finding 7): before, it returned nil into a discarded
        // result and the reader saw nothing at all.
        .alert(Text("The diagnostics file could not be saved."),
               isPresented: Binding(get: { diagnosticsFailure != nil },
                                    set: { if !$0 { diagnosticsFailure = nil } }),
               presenting: diagnosticsFailure) { _ in
            Button("Try Again") { saveDiagnostics() }  // placement: system-alert
            Button("OK", role: .cancel) {}  // placement: system-alert
        } message: { reason in
            Text(verbatim: reason)
        }
    }

    /// Writes the export, and keeps why it failed so the alert can say so.
    private func saveDiagnostics() {
        switch DiagnosticsExport.save(DiagnosticsExport.text(hover: hover, library: library)) {
        case .saved, .cancelled:
            diagnosticsFailure = nil
        case .failed(let reason):
            diagnosticsFailure = reason
        }
    }
}

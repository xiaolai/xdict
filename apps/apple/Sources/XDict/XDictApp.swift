import AppKit
import SwiftUI
import XDictAnywhere
import XDictBase
import XDictClient
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictSpeech
import XDictUI
import os
import XDictTokens

/// The app: the main window (plan-macos-v1 WI-6) — search, results and the entry — opened at launch with its search
/// field holding the keyboard, more with ⌘N; Settings (⌘,), whose Dictionaries pane is the only dictionary list
/// (ADR-0012). At launch the app asks its dictionary service for the core's versions (the E2E
/// `launch` stage's handshake) and reads the library.
struct XDictApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// The reader's, unless a development instrument runs the real app over a library of its own.
    static let setup = LookupWindowReport.setup(CommandLine.arguments) ?? AnywhereReport.setup(CommandLine.arguments)
        ?? MeasureReport.setup(CommandLine.arguments) ?? AppSetup.reader
    /// The app's one client of its dictionary service: one connection at a time, made on demand (`ServiceClient`).
    static var service: ServiceClient { setup.service }
    /// The reader's library, in the app's own Application Support (ADR-0009 decision 2), opened once at launch.
    @MainActor static let library = Library(store: LibraryStore(directory: setup.libraryDirectory), backend: service)

    var body: some Scene {
        WindowGroup(id: Self.mainWindow) {
            MainWindow()
                // Apple's Dictionary's minimum (parity P1): AX asked for 100 × 100 and took 400 × 300.
                .frame(minWidth: ToolbarLayout.minimumWindow.width, minHeight: ToolbarLayout.minimumContentHeight)
                .task { await LibraryLaunch.once() }
        }
        .defaultSize(width: 1_000, height: 700)
        .commands {
            SearchCommands()
            // The standard View items for the sidebar and the toolbar (UI review A-05).
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(after: .appSettings) {
                Button { MenuBarActions.openSetup() } label: { Text("Set Up XDict…") }
            }
            AcknowledgmentsCommand()
            FileAndHelpCommands()
        }

        // Every third-party notice (WI-10), from the app menu beside About; not in the Window menu (A-06).
        Window("Acknowledgments", id: Self.acknowledgmentsWindow) {
            AcknowledgmentsView(notices: AcknowledgmentsView.bundled())
        }
        .defaultSize(width: 640, height: 560)
        .commandsRemoved()

        // The setup board (WI-9): opened by itself once, on a fresh account, and from the app menu or Settings after.
        Window("Set Up XDict", id: Self.setupWindow) {
            SetupView(library: Self.library, registrar: LookupAnywhere.shared.registrar,
                      trusted: { AccessibilityGate.system(false) },
                      showDictionaries: { MenuBarActions.showDictionaries() })
                .task { await LibraryLaunch.once() }
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Settings {
            // Three panes, in `SettingsTab`'s order (ADR-0012 d.1). Dictionaries first: Apple's Settings opens on its
            // dictionary list (parity P39). The other two are XDict's own, at Apple's width. The pane in front is
            // `SettingsRoute`'s, so every way in can choose it (d.4).
            SettingsContent(route: .shared)
        }

        // The menu-bar item (plan-macos-v1 WI-8). Its label lives as long as the app, so it is where SwiftUI's
        // `openWindow` is handed to the panel, which expands into a main window.
        MenuBarExtra {
            MenuBarMenu(registrar: LookupAnywhere.shared.registrar,
                        lookUp: { LookupAnywhere.shared.lookUpFromMenu() },
                        openMain: { MenuBarActions.openMain() },
                        showDictionaries: { MenuBarActions.showDictionaries() })
        } label: {
            MenuBarLabel()
        }
    }

    /// One Settings pane's content (ADR-0012 d.1): the lookup shortcut sits in General, the speech rows in Reading &
    /// Speech.
    @MainActor @ViewBuilder static func settings(_ pane: SettingsTab) -> some View {
        switch pane {
        case .dictionaries:
            SettingsDictionaries(library: library, route: .shared)
                .task { await LibraryLaunch.once() }
        case .readingAndSpeech:
            ReadingSettings()
        case .general:
            GeneralSettings(login: loginItem, defaults: .standard, domain: XDictIdentity.app,
                            registrar: LookupAnywhere.shared.registrar, openSetup: { MenuBarActions.openSetup() })
        }
    }

    static let mainWindow = "main"
    static let setupWindow = "setup"
    static let acknowledgmentsWindow = "acknowledgments"
    /// XDict as its own login item (`SMAppService.mainApp`), read once and refreshed when Settings shows it.
    @MainActor static let loginItem = LaunchAtLogin(service: MainAppLoginItem())

    static func handshake() async -> LaunchStatus {
        let log = Logger(subsystem: XDictIdentity.app, category: "launch")
        switch await service.handshake() {
        case .success(let versions):
            log.info("the dictionary service answered: core \(versions.core, privacy: .public), protocol \(versions.protocolVersion)")
            return .answered(versions)
        case .failure(let failure):
            log.error("the dictionary service did not answer: \(String(describing: failure), privacy: .public)")
            return .failed(failure)
        }
    }

    /// A main window's state: the app's library and service, and an entry view of its own in the production
    /// confinement (`EntryEnvironment()`'s defaults, ADR-0009 decision 7).
    @MainActor
    /// `panel`: the lookup popover's, whose entry takes the panel layer (its density, and its page on the glass: P41).
    static func windowState(panel: Bool = false) -> SearchWindowState {
        var environment = setup.entryEvents.map { EntryEnvironment(events: $0) } ?? EntryEnvironment()
        if panel { environment.readingFrame = environment.readingFrame.union(.panel) }
        let entry = EntryViewController(environment: environment)
        return SearchWindowState(library: library, backend: service, entry: entry, window: UUID().uuidString,
                                 speech: SystemOutput(volume: setup.speechVolume),
                                 speechPreferences: SpeechPreferences(defaults: setup.speechDefaults))
    }

    /// Each main window's state as it is made: for the instrument that drives the real app (`--lookup-window`).
    @MainActor static var windowMade: ((SearchWindowState) -> Void)?
}

/// Where the app keeps its library, how it reaches its service, who hears its entry views' events, and how loud its
/// sounds are and where its speech choices are kept: the reader's own, unless a development instrument runs the real
/// app over a scratch library (`LookupWindowReport.setup`), silently, with choices of its own.
struct AppSetup: Sendable {
    let libraryDirectory: URL
    let service: ServiceClient
    let entryEvents: (@MainActor @Sendable (EntryEvent) -> Void)?
    /// 1 for the reader; 0 under an instrument, which still decodes and runs every sound to its end (WI-7).
    var speechVolume: Float = 1
    /// The defaults suite the accent is kept in; nil for the reader's own.
    var speechSuite: String?
    /// The reader's own run, not an instrument's: only it opens the setup board by itself.
    var isReader = false

    var speechDefaults: UserDefaults {
        speechSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    static var reader: AppSetup {
        AppSetup(libraryDirectory: URL.applicationSupportDirectory.appending(path: XDictIdentity.app),
                 service: ServiceClient(), entryEvents: nil, isReader: true)
    }
}

/// One main window: made once per window, asking the service at its first appearance.
struct MainWindow: View {
    @State private var state: SearchWindowState?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let state {
                SearchWindow(state: state)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard state == nil else { return }
            let made = XDictApp.windowState()
            made.showDictionaries = { SettingsRoute.shared.show($0) }
            state = made
            XDictApp.windowMade?(made)
            MainWindows.made(made)
            Task { made.service = await XDictApp.handshake() }
        }
    }
}

/// The library is read and its dictionaries opened once per launch, by whichever window appears first.
@MainActor
enum LibraryLaunch {
    private static var started = false

    static func once() async {
        guard !started else { return }
        started = true
        await XDictApp.library.start()
    }
}

/// Starts lookup from anywhere once the app has finished launching: the shortcut, the Service, the panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Main windows take tabs, as Apple's Dictionary's do (parity P32, P37): File ▸ New Tab and the Window menu's
        // tab items.
        NSWindow.allowsAutomaticWindowTabbing = true
        // The UI tour's appearance, an instrument's argument alone (refused in main.swift otherwise).
        if case .success(let chosen?) = InstrumentAppearance.parse(Array(CommandLine.arguments.dropFirst())) {
            MainActor.assumeIsolated { NSApp.appearance = chosen.appearance }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            LookupAnywhere.shared.start()
            Task { await LibraryLaunch.once() }
        }
    }
}

/// The menu-bar item's icon, and the scene actions it hands over.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Self.icon
            .accessibilityLabel(Text(verbatim: "XDict"))
            .task {
                LookupAnywhere.shared.openMainWindow = { openWindow(id: XDictApp.mainWindow) }
                MenuBarActions.open = { openWindow(id: $0) }
                // Every way into Settings ▸ Dictionaries opens Settings through here, so it works with no other window
                // open (ADR-0012 d.4).
                SettingsRoute.shared.open = {
                    NSApp.activate()
                    openSettings()
                }
                await LibraryLaunch.once()
                SetupLaunch.openOnAFreshAccount()
            }
    }

    /// The designer's 22 pt glyph (`Resources/MenuBarIcon.svg`, ported from XiaolaiDict with the app icon), marked as a
    /// template so the system draws it in the menu bar's own colour: only its alpha is read. `Tools/build-bundle.sh`
    /// refuses a bundle without it; outside a bundle (`swift run`) there is no resource, and a symbol beats an empty
    /// slot, which would leave the menu unreachable.
    private static let icon: Image = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            Logger(subsystem: XDictIdentity.app, category: "launch")
                .error("MenuBarIcon.svg is not in the bundle; the menu bar shows a system symbol")
            return Image(systemName: "character.book.closed")
        }
        image.isTemplate = true
        image.size = Tokens.Size.menuBarIcon
        return Image(nsImage: image)
    }()
}

/// What the menu-bar menu opens, through the label's `openWindow`.
@MainActor
enum MenuBarActions {
    static var open: ((String) -> Void)?

    static func openMain() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(XDictApp.mainWindow) == true
                                                     && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            open?(XDictApp.mainWindow)
        }
    }

    static func openSetup() {
        NSApp.activate()
        open?(XDictApp.setupWindow)
    }

    /// Settings ▸ Dictionaries, at `dictionary` when given (ADR-0012 d.4, d.5).
    static func showDictionaries(_ dictionary: UUID? = nil) {
        SettingsRoute.shared.show(dictionary)
    }
}

/// **Settings' panes, the one in front chosen by `SettingsRoute`** (ADR-0012 d.1, d.4).
struct SettingsContent: View {
    @Bindable var route: SettingsRoute

    var body: some View {
        TabView(selection: $route.pane) {
            ForEach(SettingsTab.allCases, id: \.self) { pane in
                Tab(value: pane) {
                    XDictApp.settings(pane)
                } label: {
                    Label { Text(pane.title) } icon: { Image(systemName: pane.symbol) }
                }
            }
        }
    }
}

/// **The setup board opens by itself once**, on the reader's first launch with no dictionaries; after that only when
/// asked (the app menu, Settings ▸ General). The flag decides only whether it opens, never what it shows.
@MainActor
enum SetupLaunch {
    static let shownKey = "setup.openedOnce"

    static func openOnAFreshAccount(defaults: UserDefaults = .standard) {
        guard XDictApp.setup.isReader, !defaults.bool(forKey: shownKey), XDictApp.library.entries.isEmpty else { return }
        defaults.set(true, forKey: shownKey)
        MenuBarActions.openSetup()
    }
}

/// XDict ▸ Acknowledgments…, right after About XDict.
struct AcknowledgmentsCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button { openWindow(id: XDictApp.acknowledgmentsWindow) } label: { Text("Acknowledgments") }
        }
    }
}

/// **File ▸ New Tab (⌘T) and Add Dictionaries… (⌘O), and Help ▸ XDict Help** (parity P32, P38; UI review A-04). New Tab
/// opens a main window as a tab of the one in front, as Apple's Dictionary's does. Help opens XDict's site in the
/// browser: no help book is bundled, and nothing of a dictionary's goes with it.
struct FileAndHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { NewTab.open { openWindow(id: XDictApp.mainWindow) } }
                .keyboardShortcut("t")
            // Settings ▸ Dictionaries with the open panel up; the pane's `+` ▸ Add MDX Files… shows the same ⌘O (ADR-0012
            // d.3).
            Button("Add Dictionaries…") { SettingsRoute.shared.requestImport() }
            .keyboardShortcut("o")
        }
        CommandGroup(replacing: .help) {
            Button("XDict Help") {
                if let site = URL(string: "https://xdict.ai") { openURL(site) }
            }
        }
    }
}

/// A new main window, put in the front main window's tab group once SwiftUI has made it.
@MainActor
enum NewTab {
    static func open(_ make: () -> Void) {
        let host = NSApp.keyWindow.flatMap { isMain($0) ? $0 : nil }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        make()
        Task { @MainActor in
            for _ in 0..<80 {
                if let made = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) && isMain($0) }) {
                    if let host, host !== made { host.addTabbedWindow(made, ordered: .above) }
                    made.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private static func isMain(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(XDictApp.mainWindow) == true
    }
}

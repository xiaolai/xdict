import AppKit
import CoreSpotlight
import SwiftUI
import XDictAnywhere
import XDictAppleSource
import XDictBase
import XDictClient
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictSpeech
import XDictSpotlight
import XDictUI
import os
import XDictTokens

/// The app: the main window (plan-macos-v1 WI-6) — search, results and the entry — opened at launch with its search
/// field holding the keyboard, more with ⌘N; Settings (⌘,), whose Dictionaries pane is the only dictionary list
/// (ADR-0012). At launch the app asks its dictionary service for the core's versions (the E2E
/// `launch` stage's handshake) and reads the library.
struct XDictApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// About XDict opens its own window from the app menu (owner, 2026-10-29).
    @Environment(\.openWindow) private var openWindow
    /// The reader's, unless a development instrument runs the real app over a library of its own.
    static let setup = LookupWindowReport.setup(CommandLine.arguments) ?? AnywhereReport.setup(CommandLine.arguments)
        ?? MeasureReport.setup(CommandLine.arguments) ?? AppSetup.reader
    /// **The reader's Spotlight switch and the run that obeys it** (plan-setup-v2 WI-6; ADR-0028): off until the reader
    /// turns it on in Setup, and then the library's words are indexed, dictionary by dictionary.
    @MainActor static let spotlightSettings = SpotlightSettings()
    /// **The one Spotlight run**: a new setting cancels the run in flight and waits for it, so an off-run can never be
    /// overtaken by an on-run's deletions or the other way round (audit-fix 2026-10-22).
    @MainActor private static var spotlightRun: Task<Void, Never>? = nil

    /// **What a Spotlight run came to, in words** (2026-10-27): the switch's own record is one boolean, so a run that
    /// failed — or one whose answer never came back — left no trace anywhere, and `cleanupPending` was the only
    /// symptom. `log show --predicate 'process == "XDict"' | grep spotlight` is now what says why.
    @MainActor static let spotlightLog = Logger(subsystem: XDictIdentity.app, category: "spotlight")

    /// Applies the switch's value, one run at a time.
    @MainActor static func applySpotlight(_ on: Bool) {
        // **Switching off cancels the queued reconciliation too** (audit round 4, 2026-10-25): an on-run must not follow a
        // deletion the reader asked for.
        if !on {
            spotlightPending?.cancel()
            spotlightPending = nil
        }
        let previous = spotlightRun
        previous?.cancel()
        spotlightRun = Task { @MainActor in
            _ = await previous?.value   // the older run finishes (or gives up) before this one begins
            // **A deletion refused after its run was recorded owes itself again** (audit, 2026-10-28): the order is
            // placed and answered later, or never; an error that does arrive puts the cleanup back in the debt, so the
            // next launch tries it instead of the row saying "not included" over words still in the index.
            let outcome = await spotlight.apply(on, onLateFailure: { why in
                Task { @MainActor in
                    XDictApp.spotlightLog.error("the deletion was refused after its run: \(why, privacy: .public)")
                    XDictApp.spotlightSettings.record(failed: true)
                }
            })
            switch outcome {
            case .indexed(let dictionaries, let words):
                spotlightLog.notice("indexed \(dictionaries) dictionaries, \(words) words")
            case .deleted(let dictionaries):
                spotlightLog.notice("deleted every XDict domain (\(dictionaries) dictionaries)")
            case .failed(let why):
                spotlightLog.error("run (on: \(on, privacy: .public)) failed: \(why, privacy: .public)")
            }
            spotlightSettings.record(failed: outcome.isFailure)
        }
    }

    /// **The index follows the library during a session too** (audit-fix 2026-10-22 finding 13): an import batch, a
    /// removal or a disable announces through `library.didSettle`, and a burst of announcements rebuilds the index once.
    @MainActor private static var spotlightPending: Task<Void, Never>? = nil

    @MainActor static func spotlightReconcile() {
        guard setup.isReader, spotlightSettings.enabled else { return }
        spotlightPending?.cancel()
        spotlightPending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            // **The switch is read again after the wait** (audit round 4): the reader may have turned it off meanwhile.
            guard !Task.isCancelled, spotlightSettings.enabled else { return }
            applySpotlight(true)
        }
    }
    @MainActor static var spotlight: SpotlightLibrary {
        SpotlightLibrary(library: library, client: service)
    }
    /// The app's one client of its dictionary service: one connection at a time, made on demand (`ServiceClient`).
    static var service: ServiceClient { setup.service }

    /// **The word data Settings installs** (plan-word-exploration WI-5): restored at launch from the app group's
    /// container, so exploration works before Settings is ever opened. The container is the shared one, never a folder
    /// of the app's own: the service's sandbox can read only that.
    @MainActor static let wordData = WordDataModel(backend: service, container: { SharedContainer.wordPack() })
    /// The reader's library, in the app's own Application Support (ADR-0009 decision 2), opened once at launch.
    @MainActor static let library = Library(store: LibraryStore(directory: setup.libraryDirectory), backend: service)
    /// **The reading history** (ADR-0023): the drawer's days and the one place a reading is recorded. The core owns every
    /// rule; the preferences are Settings ▸ Learning's, and off means nothing is written at all.
    @MainActor static let history = HistoryModel(service: service, preferences: LearningPreferences.shared)
    /// **The review session** (plan-history-and-learning §5): the due queue, a grade, an undo and a note. The core owns
    /// eligibility and scheduling; this is the reader's side of it. Every load of the summary replans the one reminder.
    @MainActor static let study: StudyModel = {
        let study = StudyModel(service: service)
        study.summaryChanged = { summary in Task { await XDictApp.reminders.refresh(summary: summary) } }
        return study
    }()
    /// **Review reminders** (plan §5.4): the reader's switch, the system's permission and the one pending notification.
    @MainActor static let reminders = ReviewReminders(preferences: LearningPreferences.shared)
    /// **The app's one sync pass** (audit 2026-10-27): startup and Settings ▸ Learning run through it, so its running guard
    /// holds across both and the pane shows what the startup pass found.
    @MainActor static let sync = SyncPass { folder in
        await ReviewSync.run(study: XDictApp.study, folder: URL(filePath: folder))
    }
    /// The drawer's one window: shown from the menu bar, refreshed each time it opens. A card's note is written into
    /// the same ledger, and Review opens the review window.
    @MainActor static let historyDrawer = HistoryDrawerController(model: history, study: study,
                                                                  onReview: { MenuBarActions.openReview() })
    /// **The menu bar item** (plan-history-and-learning §4, XiaolaiDict's port): a click opens the reading history, a
    /// right or control click opens the menu. Installed after launch, once a window's environment has handed the actions.
    @MainActor static let menuBar = MenuBarItem()
    /// Add Apple Dictionaries… and Convert Again (ADR-0011), through the app-group container the service shares.
    @MainActor static let appleImporter = AppleImporter(library: library, backend: service,
                                                        root: SharedContainer.appleImports())
    @MainActor static var appleImport: AppleImportHost {
        let root = setup.appleAssets
        return AppleImportHost(importer: appleImporter,
                               discover: { InstalledBundles.discover(root: root) },
                               available: { installed in AvailableBundles.discover(installed: installed) },
                               listing: { InstalledBundles.listing(root: root) },
                               availableEntries: { AvailableBundles.read() })
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindow) {
            MainWindow()
                // Apple's Dictionary's minimum (parity P1): AX asked for 100 × 100 and took 400 × 300. The window's, not
                // a SwiftUI frame's: around the split view that became the entry column's least, and the first search's
                // results list widened a 400 pt window to 584 pt (`WindowMinimum`). Zero removes the content minimum.
                .frame(minWidth: 0, minHeight: 0)
                .background(WindowMinimum(ToolbarLayout.minimumWindow))
                .task { await LibraryLaunch.once() }
        }
        .defaultSize(width: Tokens.Window.mainIdealWidth, height: Tokens.Window.mainIdealHeight)
        .commands {
            SearchCommands()
            // The standard View items for the sidebar and the toolbar (UI review A-05).
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(after: .appSettings) {  // placement: P31
                Button { MenuBarActions.openSetup() } label: { Text("Set Up XDict…") }
            }
            AcknowledgmentsCommand()
            // **About XDict opens XDict's own panel** (owner, 2026-10-29: "我们竟然没有一个 about menu"): this copy's
            // numbers, its licence, its site and source, and the update check — in place of the system's stock panel,
            // which said the name and a version and nothing XDict could correct. Acknowledgments stays after it.
            CommandGroup(replacing: .appInfo) {  // placement: P31
                Button { openWindow(id: XDictApp.aboutWindow) } label: { Text("About XDict") }
            }
            FileAndHelpCommands()
            // **⌘Q closes the window, and Quit lives in the menu-bar icon's menu alone** (owner, 2026-10-27: "the only way
            // to quit xdict is by tray icon menu"): the app menu's Quit goes with its termination command, and the key
            // every reader reaches for closes the window in front instead.
            CommandGroup(replacing: .appTermination) {  // placement: P31
                Button { MainActor.assumeIsolated { NSApp.keyWindow?.performClose(nil) } } label: {
                    Text("Close Window")
                }
                .keyboardShortcut("q")
            }
        }

        // **About XDict**, from the app menu (owner, 2026-10-29), and the same content as Settings' last pane.
        Window("About XDict", id: Self.aboutWindow) {
            AboutPane()
        }
        .defaultSize(width: Tokens.Window.aboutWidth, height: Tokens.Window.aboutHeight)
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        // Every third-party notice (WI-10), from the app menu beside About; not in the Window menu (A-06).
        Window("Acknowledgments", id: Self.acknowledgmentsWindow) {
            AcknowledgmentsView(notices: AcknowledgmentsView.bundled())
        }
        .defaultSize(width: Tokens.Window.acknowledgmentsIdealWidth,
                     height: Tokens.Window.acknowledgmentsIdealHeight)
        .commandsRemoved()

        // **The review window** (plan-history-and-learning §5): the card in front, its note and the four answers.
        Window("Review", id: Self.reviewWindow) {
            ReviewView(model: Self.study)
        }
        .defaultSize(width: Tokens.Window.reviewWidth, height: Tokens.Window.reviewHeight)

        Settings {
            // Three panes, in `SettingsTab`'s order (ADR-0012 d.1). Dictionaries first: Apple's Settings opens on its
            // dictionary list (parity P39). The other two are XDict's own, at Apple's width. The pane in front is
            // `SettingsRoute`'s, so every way in can choose it (d.4).
            SettingsContent(route: .shared)
        }

    }

    /// One Settings pane's content (ADR-0012 d.1): the lookup shortcut sits in General, the speech rows in Reading &
    /// Speech.
    @MainActor @ViewBuilder static func settings(_ pane: SettingsTab) -> some View {
        switch pane {
        case .dictionaries:
            SettingsDictionaries(library: library, route: .shared, appleImport: appleImport, study: study,
                                 wordData: wordData)
                .task { await LibraryLaunch.once() }
        case .readingAndSpeech:
            ReadingSettings()
        case .learning:
            // The library's declared search languages: the values the recording filter and the drawer offer (ADR-0023).
            LearningSettings(declared: { library.declaredSearchLanguages }, study: study, reminders: reminders,
                             sync: XDictApp.sync)
        case .general:
            GeneralSettings(login: loginItem, defaults: .standard, domain: XDictIdentity.app,
                            registrar: LookupAnywhere.shared.registrar, hover: LookupAnywhere.shared.hover)
        case .ai:
            AISettings()
        case .setup:
            SetupView(library: library, registrar: LookupAnywhere.shared.registrar,
                      trusted: { AccessibilityGate.system(false) },
                      showDictionaries: { MenuBarActions.showDictionaries() },
                      hover: LookupAnywhere.shared.hover,
                      spotlight: spotlightSettings,
                      aiConfigured: { MeaningPreferences.shared.settings.source != nil },
                      onSpotlight: { on in XDictApp.applySpotlight(on) })
                .task { await LibraryLaunch.once() }
        case .about:
            AboutPane()
        }
    }

    static let mainWindow = "main"
    static let acknowledgmentsWindow = "acknowledgments"
    static let aboutWindow = "about"
    static let reviewWindow = "review"
    /// XDict as its own login item (`SMAppService.mainApp`), read once and refreshed when Settings shows it.
    @MainActor static let loginItem = LaunchAtLogin(service: MainAppLoginItem())

    static func handshake() async -> LaunchStatus {
        let log = Logger(subsystem: XDictIdentity.app, category: "launch")
        switch await service.handshake() {
        case .success(let versions):
            log.notice("the dictionary service answered: core \(versions.core, privacy: .public), protocol \(versions.protocolVersion)")
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
        let state = SearchWindowState(library: library, backend: service, entry: entry, window: UUID().uuidString,
                                      speech: SystemOutput(volume: setup.speechVolume),
                                      speechPreferences: SpeechPreferences(defaults: setup.speechDefaults))
        // **The pane's Save as Note** (plan-companion WI-9; owner, 2026-10-25): the app's study model, behind the reader's
        // explicit tap; a note already on the entry is replaced only after the pane asks.
        // **The store checks and writes as one** (audit rounds 1–4, 2026-10-26): the pane no longer asks first, so a note
        // saved between the question and the write cannot be replaced unseen.
        // **The pack comes back with the panel** (audit, 2026-10-28): `restore()` asks the service what it holds and
        // attaches the container's file only when it holds none, so this costs one short call when all is well.
        state.prepareWordData = { await XDictApp.wordData.restore() }
        state.noteSaver = { entry, text, name, replacing in
            await XDictApp.study.saveNote(entry: entry, text: text, name: name, replacing: replacing)
        }
        return state
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
    /// The reader's own run, not an instrument's: only it opens the setup board by itself, and only it sweeps the
    /// shared container's Apple conversions (an instrument's scratch library names none of the reader's).
    var isReader = false
    /// Where installed Apple dictionaries are found (ADR-0011 decision 11): the AssetsV2 path, or under an instrument,
    /// a synthetic tree of its own (`--apple-assets`).
    var appleAssets = InstalledBundles.systemRoot

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
    @Environment(\.openSettings) private var openSettings

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
            // **The menu bar item's routes to the app's scenes**, captured here because `openWindow` and `openSettings`
            // live in a view's environment and the item is AppKit. The main window opens at every launch, so these exist
            // before a reader can click the icon.
            LookupAnywhere.shared.openMainWindow = {
                NewTabLookups.shared.cancel()
                openWindow(id: XDictApp.mainWindow)
            }
            MenuBarActions.open = { openWindow(id: $0) }
            // Every way into Settings ▸ Dictionaries opens Settings through here, so it works with no other window open
            // (ADR-0012 d.4).
            SettingsRoute.shared.open = {
                NSApp.activate()
                openSettings()
            }
            let made = XDictApp.windowState()
            made.showDictionaries = { SettingsRoute.shared.show($0) }
            // A ⌘-clicked word opens in a new tab of this window, looked up as typed and Return (P47).
            made.openInNewTab = { [openWindow] word in
                // **The word is handed inside the queue** (verification 2026-10-27): NewTab serialises window creation, so
                // a word handed before the queue would be overwritten by the next request before its window existed.
                NewTab.open(make: {
                    NewTabLookups.shared.hand(word)
                    openWindow(id: XDictApp.mainWindow)
                }, failed: { NewTabLookups.shared.failed(word) })
            }
            if let word = NewTabLookups.shared.take() {
                Task {
                    await LibraryLaunch.once()
                    made.model.submit(word)
                }
            }
            state = made
            XDictApp.windowMade?(made)
            MainWindows.made(made)
            // **The place may be waiting for the service** (owner, 2026-10-26): a window the expansion made adopts its
            // place before this handshake answers, and an entry cannot be drawn through a service that is not there.
            Task {
                made.service = await XDictApp.handshake()
                made.placeCanBeDrawn()
            }
        }
        // **A Spotlight result opens its word here** (ADR-0028 decision 4): the item's identifier carries the word, and
        // the window looks it up exactly as the reader typing it would.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let item = SpotlightItem.item(of: identifier) else { return }
            Task {
                await LibraryLaunch.once()
                // **The result's own dictionary is selected first** (audit-fix 2026-10-22 finding 15): the item's domain
                // is the library entry's id, so a window scoped to another dictionary shows this word instead of
                // nothing. A dictionary no longer enabled or open leaves the scope as it was.
                if let domain = UUID(uuidString: item.domain), state?.model.source(domain) != nil,
                   XDictApp.library.entries.contains(where: { $0.id == domain && $0.enabled }),
                   XDictApp.library.handle(domain) != nil {
                    state?.model.setScope(.one(domain))
                }
                state?.model.submit(item.word)
            }
        }
    }
}

/// The library is read and its dictionaries opened once per launch, by whichever window appears first.
@MainActor
enum LibraryLaunch {
    private static var launch: Task<Void, Never>?

    /// **The launch work runs once, and every caller waits for it** (audit round 4, 2026-10-25): a second caller used to
    /// return while the library was still starting, so a search could be submitted before its dictionaries were open.
    static func once() async {
        if let launch {
            await launch.value
            return
        }
        let task = Task { await run() }
        launch = task
        await task.value
    }

    private static func run() async {
        await XDictApp.library.start()
        // **Announcements from here on** (audit-fix 2026-10-22 finding 13): the launch's own settle has been read, and
        // the index is given its launch run below; a later import, removal or disable is announced through this.
        XDictApp.library.didSettle = { XDictApp.spotlightReconcile() }
        // Plan-word-exploration WI-5: the service starts holding no pack, so the container's is attached — **not
        // awaited**: attaching parses 183 MB in the service and the launch's own work must not wait for it. A panel
        // asked for a pack mode in the first seconds says what Settings will then correct.
        if XDictApp.setup.isReader { Task { await XDictApp.wordData.restore() } }
        // ADR-0011 decisions 7 and 9: the launch sweep, then each Apple dictionary compared with its installed bundle.
        if XDictApp.setup.isReader { XDictApp.appleImporter.sweep() }
        // **The index follows the library when the reader asked for it** (audit-fix 2026-10-22): the switch is kept
        // across launches, so a launch with it on indexes again — a dictionary imported or replaced since the last run
        // is included, and the run is the same one the toggle starts.
        // **The reader's own run only**: an instrument's scratch library must never index itself into the reader's index.
        if XDictApp.setup.isReader {
            if XDictApp.spotlightSettings.enabled {
                XDictApp.applySpotlight(true)
            } else if XDictApp.spotlightSettings.needsCleanup() {
                XDictApp.applySpotlight(false)   // a deletion a failed run still owed (audit-fix 2026-10-22)
            }
        }
        let host = XDictApp.appleImport
        if !XDictApp.library.importedAppleBundles.isEmpty {
            await host.importer.checkForUpdates(installed: await host.find())
        }
    }
}

/// Starts lookup from anywhere once the app has finished launching: the shortcut, the Service, the panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // **The reader's Dock choice, before the first window draws** (owner, 2026-10-27): off means an accessory app — no
        // Dock icon, the menu bar's icon instead — and a regular app only when the reader asked for one.
        DockVisibility(defaults: .standard).apply()
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
            // The summary plans the reminder before any window asks for it (plan §5.4).
            Task { await XDictApp.study.refresh() }
            // **A join moves the lineage's notes** (plan §5.1): the reader said the changed file is the same dictionary,
            // so what they wrote about it follows the new edition where the definition is still there.
            XDictApp.library.didJoin = { old, new in
                Task { await XDictApp.study.reanchor(from: old, to: new) }
            }
            // **A sync folder set once syncs by itself** (plan §2.6): the logs meet before the reader looks. It runs
            // through the app's one `SyncPass` (audit 2026-10-27), so a Settings ▸ Learning "Sync Now" during startup
            // cannot start a second pass over the same inbox, and what the startup pass found — a success's time, or a
            // folder that no longer opens — reaches the pane instead of being dropped.
            Task { await XDictApp.sync.run(LearningPreferences.shared.syncFolder) }
            // **The app's own menu bar item** (XiaolaiDict's port): a click shows the reading history on the display it was
            // clicked on, a right or control click opens the menu, and the item highlights while the drawer is open.
            XDictApp.historyDrawer.statusItemFrame = { XDictApp.menuBar.screenFrame }
            XDictApp.historyDrawer.onVisibilityChange = { XDictApp.menuBar.historyBecame(visible: $0) }
            XDictApp.menuBar.install()
            Task {
                await LibraryLaunch.once()
                SetupLaunch.openOnAFreshAccount()
            }
        }
    }

    /// **Closing a window never quits** (owner, 2026-10-27: "cmd+w, or cmd+q, only close xdict window, keep it running in
    /// background, only showing tray icon, the only way to quit xdict is by tray icon menu"): the last window closing
    /// leaves XDict in the menu bar, whatever the reader chose about the Dock icon, and the menu-bar icon's Quit is the
    /// one way out.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// What the menu-bar item's menu opens, through the environment a window handed over at launch.
@MainActor
enum MenuBarActions {
    static var open: ((String) -> Void)?

    static func openMain() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(XDictApp.mainWindow) == true
                                                     && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NewTabLookups.shared.cancel()
            open?(XDictApp.mainWindow)
        }
    }

    /// **Set Up XDict… opens Settings ▸ Setup** (ADR-0012, amended 2026-10-20): the board is a pane now, and the setup
    /// window is gone, so every way in is one window.
    static func openSetup() {
        NSApp.activate()
        SettingsRoute.shared.showSetup()
    }

    /// Settings ▸ Dictionaries, at `dictionary` when given (ADR-0012 d.4, d.5).
    static func showDictionaries(_ dictionary: UUID? = nil) {
        SettingsRoute.shared.show(dictionary)
    }

    /// **The review window** (plan-history-and-learning §5): opened from the menu-bar menu and from the drawer's own
    /// header, brought forward when it is already open.
    @MainActor static func openReview() {
        // The drawer closes first: the review window takes the reader's attention, and a popover behind it would keep
        // clicks of its own (a click outside already closes it).
        XDictApp.historyDrawer.hide()
        NSApp.activate()
        open?(XDictApp.reviewWindow)
    }

    /// **The reading history's drawer** (plan-history-and-learning §4): a click on the menu-bar icon shows it — on the
    /// display the icon is on — and a repeated click keeps it open (XiaolaiDict's decision, kept).
    @MainActor static func showHistory() {
        XDictApp.historyDrawer.show()
    }

    /// Settings, from the menu bar: through the environment a window handed over at launch (`openSettings` lives in a
    /// SwiftUI view's environment; the item is AppKit).
    @MainActor static func openSettings() {
        NSApp.activate()
        SettingsRoute.shared.open?()
    }
}

/// **Settings' panes at the left, the chosen one at the right** (ADR-0012 d.1, d.4; amended 2026-10-20 to a sidebar):
/// Apple's own apps have listed their settings down one side for years, and a reader who is looking for the setup board
/// finds it in the same window as everything else. The detail keeps Apple's 600 pt width (P39); the sidebar is one more
/// way to choose a pane, not another place.
struct SettingsContent: View {
    @Bindable var route: SettingsRoute

    /// The list's one selection, over the route's pane: a click (or the arrow keys) moves the whole window.
    private var selection: Binding<SettingsTab?> {
        Binding(get: { route.pane }, set: { if let pane = $0 { route.pane = pane } })
    }

    /// The sidebar's search (UI30): while it holds words the sidebar lists matching rows; cleared, the six panes.
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .searchable(text: $query, placement: .sidebar, prompt: Text("Search Settings"))
                .listStyle(.sidebar)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: Tokens.Window.settingsSidebar, ideal: Tokens.Window.settingsSidebar,
                                                max: Tokens.Window.settingsSidebar)
        } detail: {
            // The chosen pane at the top of the detail, scrolling inside it when it is taller than the window: a pane
            // never stretches its controls to fill, and switching panes never resizes the window.
            // A revealed row is scrolled to once its pane has drawn it (UI30).
            SettingsRevealScroll(route: route) {
                XDictApp.settings(route.pane)
            }
            // **The selected pane's name over it** (UI31), as System Settings titles its detail.
            .navigationTitle(Text(route.pane.paneTitle))
        }
        // **A fixed sidebar with no toggle**: the panes are the window's whole navigation, and hiding it would leave no
        // way to switch (Apple's Settings has no such button). One window size for every pane (ADR-0012 d.6).
        .toolbar(removing: .sidebarToggle)
        .frame(width: SettingsDictionaries.paneWidth + Tokens.Window.settingsSidebar,
               height: Tokens.Window.settingsHeight)
    }

    /// The six panes, or — while searching — the rows that match, each naming its pane; choosing one reveals it.
    @ViewBuilder private var sidebar: some View {
        if !SettingsSearch.isSearching(query) {
            List(SettingsTab.allCases, id: \.self, selection: selection) { pane in
                Label { Text(pane.title) } icon: { Image(systemName: pane.symbol) }
                    .tag(pane)
            }
        } else {
            let results = SettingsSearch.results(query)
            List {
                ForEach(results) { item in
                    Button { route.reveal(item) } label: {  // placement: settings-search-result
                        Label {
                            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                                Text(item.title)
                                Text(item.pane.title).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: item.pane.symbol)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.search.\(item.anchor.rawValue)")
                }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
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
        SettingsRoute.shared.showSetup()
    }
}

/// XDict ▸ Acknowledgments…, right after About XDict.
struct AcknowledgmentsCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {  // placement: P31
            Button { openWindow(id: XDictApp.acknowledgmentsWindow) } label: { Text("Acknowledgments") }
        }
    }
}

/// **About, in its window and as Settings' last pane** (owner, 2026-10-29): one view, so the two cannot say different
/// things; the acknowledgments the panel links to open beside whichever one is in front.
struct AboutPane: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AboutView(acknowledge: { openWindow(id: XDictApp.acknowledgmentsWindow) })
    }
}

/// **File ▸ New Tab (⌘T) and Add Dictionaries… (⌘O), and Help ▸ XDict Help** (parity P32, P38; UI review A-04). New Tab
/// opens a main window as a tab of the one in front, as Apple's Dictionary's does. Help opens XDict's site in the
/// browser: no help book is bundled, and nothing of a dictionary's goes with it.
struct FileAndHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(after: .newItem) {  // placement: P32
            Button("New Tab") {
                NewTabLookups.shared.cancel()   // a word ⌘-clicked earlier is not this tab's (P47)
                NewTab.open(make: { openWindow(id: XDictApp.mainWindow) })
            }
                .keyboardShortcut("t")
            // Settings ▸ Dictionaries with the open panel up; the pane's `+` ▸ Add MDX Files… shows the same ⌘O (ADR-0012
            // d.3).
            Button("Add Dictionaries…") { SettingsRoute.shared.requestImport() }
            .keyboardShortcut("o")
        }
        CommandGroup(replacing: .help) {  // placement: P38
            Button("XDict Help") {
                if let site = URL(string: "https://xdict.ai") { openURL(site) }
            }
        }
    }
}

/// A new main window, put in the front main window's tab group once SwiftUI has made it.
@MainActor
enum NewTab {
    /// **One request at a time** (audit 2026-10-27): two requests taken together snapshotted the same existing windows, so
    /// both could claim the first window either of them made — the second left untabbed, or tabbed into the wrong host.
    /// Each waits for the one before it to have claimed its own window.
    @ObservationIgnored private static var pending: Task<Void, Never>?

    /// `failed` runs when no new main window appeared within `NewTabLookups.bound`.
    static func open(make: @escaping () -> Void, failed: @escaping @MainActor () -> Void = {}) {
        let previous = pending
        pending = Task { @MainActor in
            await previous?.value
            let host = NSApp.keyWindow.flatMap { isMain($0) ? $0 : nil }
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            make()
            for _ in 0..<80 {
                if let made = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) && isMain($0) }) {
                    if let host, host !== made { host.addTabbedWindow(made, ordered: .above) }
                    made.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            failed()
        }
    }

    private static func isMain(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(XDictApp.mainWindow) == true
    }
}

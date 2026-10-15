import SwiftUI
import XDictBase
import XDictClient
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictUI
import os

/// The app: the main window (plan-macos-v1 WI-6) — search, results and the entry — opened at launch with its search
/// field holding the keyboard, more with ⌘N; the library window (WI-5), from the main window or with ⌘⇧L. At launch the
/// app asks its dictionary service for the core's versions (the E2E `launch` stage's handshake) and reads the library.
struct XDictApp: App {
    /// The reader's, unless a development instrument runs the real app over a library of its own.
    static let setup = LookupWindowReport.setup(CommandLine.arguments) ?? AppSetup.reader
    /// The app's one client of its dictionary service: one connection at a time, made on demand (`ServiceClient`).
    static var service: ServiceClient { setup.service }
    /// The reader's library, in the app's own Application Support (ADR-0009 decision 2), opened once at launch.
    @MainActor static let library = Library(store: LibraryStore(directory: setup.libraryDirectory), backend: service)

    var body: some Scene {
        WindowGroup(id: Self.mainWindow) {
            MainWindow()
                .frame(minWidth: 640, minHeight: 420)
                .task { await LibraryLaunch.once() }
        }
        .defaultSize(width: 1_000, height: 700)
        .commands { SearchCommands() }

        Window("Library", id: Self.libraryWindow) {
            LibraryView(library: Self.library)
                .frame(minWidth: 640, minHeight: 400)
                .task { await LibraryLaunch.once() }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }

    static let mainWindow = "main"
    static let libraryWindow = "library"

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
    static func windowState() -> SearchWindowState {
        let entry = setup.entryEvents.map { EntryViewController(environment: EntryEnvironment(events: $0)) }
            ?? EntryViewController()
        return SearchWindowState(library: library, backend: service, entry: entry, window: UUID().uuidString)
    }

    /// Each main window's state as it is made: for the instrument that drives the real app (`--lookup-window`).
    @MainActor static var windowMade: ((SearchWindowState) -> Void)?
}

/// Where the app keeps its library, how it reaches its service, and who hears its entry views' events: the reader's
/// own, unless a development instrument runs the real app over a scratch library (`LookupWindowReport.setup`).
struct AppSetup: Sendable {
    let libraryDirectory: URL
    let service: ServiceClient
    let entryEvents: (@MainActor @Sendable (EntryEvent) -> Void)?

    static var reader: AppSetup {
        AppSetup(libraryDirectory: URL.applicationSupportDirectory.appending(path: XDictIdentity.app),
                 service: ServiceClient(), entryEvents: nil)
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
            made.openLibrary = { _ in openWindow(id: XDictApp.libraryWindow) }
            state = made
            XDictApp.windowMade?(made)
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

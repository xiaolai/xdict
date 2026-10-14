import SwiftUI
import XDictBase
import XDictClient
import XDictEntryView
import XDictLibrary
import XDictUI
import os

/// The skeleton's app: one window, which asks the dictionary service for its core's versions as the app launches and
/// says what came back — and whether entries can be shown confined on this Mac (ADR-0009 decision 7: the two WebKit
/// switches read back at launch; with either missing or still on, no entry will render, and the window says why) —
/// and the library window (plan-macos-v1 WI-5), opened from it or with ⌘⇧L.
struct XDictApp: App {
    /// The app's one client of its dictionary service: one connection at a time, made on demand (`ServiceClient`).
    static let service = ServiceClient()
    /// The reader's library, in the app's own Application Support (ADR-0009 decision 2), opened once at launch.
    @MainActor static let library = Library(store: LibraryStore(directory: libraryDirectory), backend: service)
    static let libraryDirectory = URL.applicationSupportDirectory.appending(path: XDictIdentity.app)

    var body: some Scene {
        WindowGroup {
            LaunchWindow()
                .task { await LibraryLaunch.once() }
        }
        .windowResizability(.contentSize)

        Window("Library", id: Self.libraryWindow) {
            LibraryView(library: Self.library)
                .frame(minWidth: 640, minHeight: 400)
                .task { await LibraryLaunch.once() }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }

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

    @MainActor
    static func entryReadiness() -> LocalizedStringResource {
        switch EntryReadiness.check() {
        case .success: EntrySentences.ready
        case .failure(let why): EntrySentences.refusal(why)
        }
    }
}

/// The launch window's content: the handshake, the entry view's readiness, and the way to the library.
struct LaunchWindow: View {
    @State private var status = LaunchStatus.asking
    @State private var entries: LocalizedStringResource?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LaunchView(status: status)
                .task { status = await XDictApp.handshake() }
            if let entries {
                Text(entries).foregroundStyle(.secondary).padding([.horizontal, .bottom], 24)
            }
            Button("Open Library") { openWindow(id: XDictApp.libraryWindow) }
                .padding([.horizontal, .bottom], 24)
        }
        .task { entries = XDictApp.entryReadiness() }
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

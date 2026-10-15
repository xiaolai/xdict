import AppKit
import SwiftUI
import WebKit
import XDictClient
import XDictContract
import XDictEntryView
import XDictLibrary
import XDictSearch
import XDictSpeech
import XDictUI

/// **A main window an instrument makes** (plan-macos-v1 WI-6; the WI-4 entry checks re-measured through the app): the
/// production `SearchWindow` over a state of its own, in a plain window at a fixed place, its entry view in the
/// production confinement, reading through the app's own service. Only what is observed differs from the reader's
/// window: its entry view's events are recorded, a remote link it would open is recorded instead, its zoom, appearance
/// and accent are kept in defaults suites of the instrument's, never the reader's, and its sounds are silent (volume 0:
/// decoded, started and run to their end, unheard on the shared E2E Mac).
@MainActor
final class InstrumentWindow {
    /// Where the instruments keep the accent: never the reader's choice.
    nonisolated static let speechSuite = "ai.xdict.app.e2e.speech"

    let state: SearchWindowState
    let window: NSWindow
    let log: EntryEventLog
    /// The latest of the model's entries the window has handed to its entry view.
    private(set) var presented = -1

    init(_ title: String, frame: NSRect, library: Library, backend: ServiceClient, suite: String,
         opener: any EntryURLOpener, also: (@MainActor (EntryEvent) -> Void)? = nil,
         speech: any PronunciationOutput = SystemOutput(volume: 0),
         speechPreferences: SpeechPreferences = SpeechPreferences(
            defaults: UserDefaults(suiteName: InstrumentWindow.speechSuite) ?? .standard)) {
        let log = EntryEventLog()
        self.log = log
        let environment = EntryEnvironment(
            preferences: EntryPreferences(defaults: UserDefaults(suiteName: suite) ?? .standard), opener: opener,
            events: { event in
                log.note(event)
                also?(event)
            })
        state = SearchWindowState(library: library, backend: backend, entry: EntryViewController(environment: environment),
                                  window: title, speech: speech, speechPreferences: speechPreferences)
        let screen = NSScreen.main?.frame ?? .zero
        window = NSWindow(contentRect: NSRect(x: frame.minX, y: screen.maxY - frame.maxY, width: frame.width,
                                              height: frame.height),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentView = NSHostingView(rootView: SearchWindow(state: state))
        window.orderFrontRegardless()
        state.onPresented = { [weak self] shown, done in
            if done, let self { self.presented = max(self.presented, shown.serial) }
        }
    }

    /// Waits until the entry the window's model shows now has been handed to the entry view and has loaded there; that
    /// entry, or nil. An entry handed over is requested first, so a load finished before it never counts.
    func shownAndLoaded(within limit: Duration) async -> SearchModel.Shown? {
        await shown(within: limit) { reference in self.log.finished(reference) }
    }

    /// Waits until the entry the window's model shows now has been handed to the entry view, whether or not WebKit has
    /// finished loading it (a page with media can stay loading, in the lab's window as in this one); that entry, or nil.
    func handedOver(within limit: Duration) async -> SearchModel.Shown? {
        await shown(within: limit) { _ in true }
    }

    private func shown(within limit: Duration, and done: (EntryReference) -> Bool) async -> SearchModel.Shown? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let shown = state.model.shown, presented >= shown.serial {
                let reference = EntryReference(key: shown.result.entry.key, occurrence: shown.result.entry.occurrence)
                if state.entry.reference == reference, done(reference) { return shown }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
        state.entry.closeEntry()
        window.contentView = nil
        window.close()
    }
}

/// What one entry view said, with when.
@MainActor
final class EntryEventLog {
    private(set) var events: [(time: Double, event: EntryEvent)] = []
    /// The reference last requested, and whether its document has finished since.
    private var requested: EntryReference?
    private var done = false

    func note(_ event: EntryEvent) {
        events.append((Date().timeIntervalSince1970, event))
        switch event {
        case .documentRequested(let reference):
            requested = reference
            done = false
        case .documentFinished:
            done = true
        default:
            break
        }
    }

    func finished(_ reference: EntryReference) -> Bool {
        requested == reference && done
    }

    var described: [[String: Any]] {
        events.map { ["t": $0.time, "event": Self.describe($0.event)] }
    }

    /// Answered by the scheme handler since `since`: what the core resolved (200) or the dictionary lacks (404).
    func served(since: Double) -> [(url: String, status: Int)] {
        events.compactMap {
            guard $0.time >= since, case .served(_, let url, let status, _, _) = $0.event else { return nil }
            return (url, status)
        }
    }

    static func describe(_ event: EntryEvent) -> String {
        let text = String(describing: event)
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }
}

/// An opener that opens nothing: what the view asked to open, recorded.
final class RecordingOpener: EntryURLOpener {
    private(set) var opened: [String] = []
    func open(_ url: URL) { opened.append(url.absoluteString) }
}

/// The page, read in a content world of the instruments' own: the page's own configuration stays the production one.
@MainActor
enum InstrumentPage {
    static let world = WKContentWorld.world(name: "xdict-app-instrument")

    static func evaluate(_ webView: WKWebView?, _ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
        guard let webView else { return nil }
        return try? await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
    }

    /// Diagnostic SPI, read only by the instruments, never by the reader's windows: which WebKit process served a web
    /// view, so the hostile analysis can name a line in mDNSResponder's log that carries no delegator (as the lab does).
    static func pid(_ webView: WKWebView, _ name: String) -> Any {
        let selector = NSSelectorFromString(name)
        guard webView.responds(to: selector), let method = webView.method(for: selector) else { return NSNull() }
        typealias Getter = @convention(c) (NSObject, Selector) -> Int32
        return Int(unsafeBitCast(method, to: Getter.self)(webView, selector))
    }

    static var webKitVersion: String {
        Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}

/// One JSON report, written whole or not at all.
func writeReport(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

/// The library an instrument's windows read: `directory`'s, started, with `add` added if not there yet, settled.
@MainActor
func instrumentLibrary(_ directory: URL, client: ServiceClient, adding add: [URL], within limit: Duration) async
    -> (Library, Bool) {
    let library = Library(store: LibraryStore(directory: directory), backend: client)
    await library.start()
    // Compared, and handed to the library, as canonical paths: the client opens nothing through a link.
    let have = Set(library.entries.compactMap { $0.mdx?.location.path })
    let wanted = add.map { $0.resolvingSymlinksInPath() }
        .filter { folder in !have.contains { $0.hasPrefix(folder.path + "/") } }
    if !wanted.isEmpty { library.add(wanted) }
    return (library, await library.settled(within: limit))
}

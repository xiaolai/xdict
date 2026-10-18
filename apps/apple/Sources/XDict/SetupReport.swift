import AppKit
import Foundation
import SwiftUI
import XDictAnywhere
import XDictClient
import XDictEntryView
import XDictInstruments
import XDictLibrary
import XDictUI

/// `XDict --setup-report <first|second> --library-dir <dir> --suite <name> --work <dir> --out <file>`: a development
/// instrument for the E2E `setup` stage (plan-macos-v1 WI-9, done-when; run on the E2E Mac only: it opens a window).
/// **The production setup board** over an empty library of its own, its rows read back through the window's
/// Accessibility tree as the stage reads it from outside (`WindowReader`: `keys ax` answering checkpoints in `--work`):
///
/// - `first`: each row shows its live state (dictionaries needed on an empty library); Accessibility reads "needed"
///   while the trust check is held false, and completes by itself, no relaunch, once the check is let through to the
///   system's (XDict.app holds the grant on the E2E Mac); launch at login registers through `SMAppService` and its
///   status reads back (then unregistered again); a non-default accent and the Chinese UI are chosen in `--suite`.
/// - `second`, a new launch, with `-AppleLanguages (zh-Hans)`: the choices of `first` are still there, and no English
///   word appears in the setup board's Accessibility tree.
enum SetupReport {
    static let flag = "--setup-report"

    @MainActor
    static func run(_ arguments: [String]) -> Never {
        let usage = "\(flag) <first|second> --library-dir <dir> --suite <name> --work <dir> --out <file>"
        guard let phase = Instrument.value(after: flag, in: arguments), ["first", "second"].contains(phase),
              let directory = Instrument.value(after: "--library-dir", in: arguments).map(URL.init(fileURLWithPath:)),
              let suite = Instrument.value(after: "--suite", in: arguments),
              let defaults = UserDefaults(suiteName: suite),
              let work = Instrument.value(after: "--work", in: arguments).map(URL.init(fileURLWithPath:)),
              let out = Instrument.value(after: "--out", in: arguments).map(URL.init(fileURLWithPath:)) else {
            FileHandle.standardError.write(Data("usage: \(usage)\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            let library = Library(store: LibraryStore(directory: directory), backend: ServiceClient())
            await library.start()
            let reader = WindowReader(work: work)
            let findings = await (phase == "first" ? first(library: library, defaults: defaults, reader: reader)
                                                   : second(library: library, defaults: defaults, suite: suite,
                                                            reader: reader))
            do {
                try findings.json().write(to: out, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("the report could not be written: \(error)\n".utf8))
                exit(1)
            }
            exit(findings.passed ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    /// A trust check held false until released, then the system's.
    @MainActor
    final class HeldTrust {
        var released = false
        func check() -> Bool { released && AccessibilityGate.system(false) }
    }

    @MainActor
    static func first(library: Library, defaults: UserDefaults, reader: WindowReader) async -> Findings {
        var findings = Findings()
        let trust = HeldTrust()
        let window = show(library: library, trusted: { trust.check() })
        let before = await reader.identifiers(waitingFor: "setup.accessibility.needed")
        findings.check("setup.rowsLive",
                       before.contains("setup.dictionaries.needed") && before.contains("setup.accessibility.needed")
                           && before.contains(where: { $0.hasPrefix("setup.shortcut.") }),
                       "rows on an empty library: \(before.filter { $0.hasPrefix("setup.") }.sorted())\(reader.note)")
        trust.released = true
        let after = await reader.identifiers(waitingFor: "setup.accessibility.done")
        findings.check("setup.grantCompletesRow", after.contains("setup.accessibility.done"),
                       "after the grant, without relaunch: \(after.filter { $0.hasPrefix("setup.accessibility") })"
                           + reader.note)

        let login = LaunchAtLogin(service: MainAppLoginItem())
        login.set(true)
        let registered = login.status
        login.set(false)
        findings.check("setup.loginItemRegisters", registered == .enabled || registered == .requiresApproval,
                       "SMAppService status after register: \(registered); after unregister: \(login.status); \(login.failure ?? "")")

        EntryPreferences(defaults: defaults).setAccent(.indigo)
        InterfaceLanguage.simplifiedChinese.apply(to: defaults)
        findings.fact("chosen", "accent indigo, language zh-Hans")
        window.close()
        return findings
    }

    @MainActor
    static func second(library: Library, defaults: UserDefaults, suite: String, reader: WindowReader) async -> Findings {
        var findings = Findings()
        let accent = EntryPreferences(defaults: defaults).accent()
        let language = InterfaceLanguage.current(in: defaults, domain: suite)
        findings.check("setup.choicesPersist", accent == .indigo && language == .simplifiedChinese,
                       "after relaunch: accent \(accent.rawValue), language \(language.rawValue)")
        let window = show(library: library, trusted: { AccessibilityGate.system(false) })
        _ = await reader.identifiers(waitingFor: "setup.dictionaries.needed")
        let read = SetupWindowReading.contentTexts(await reader.read())
        let english = SetupLanguageCheck.english(in: read)
        findings.check("setup.chineseOnly",
                       SetupLanguageCheck.chineseOnly(texts: read, preferredLanguage: Locale.preferredLanguages.first),
                       "languages \(Locale.preferredLanguages.prefix(2)); \(read.count) texts read; English left: "
                           + "\(english)\(reader.note)")
        window.close()
        return findings
    }

    @MainActor
    static func show(library: Library, trusted: @escaping @MainActor () -> Bool) -> NSWindow {
        let view = SetupView(library: library, registrar: LookupAnywhere.shared.registrar, trusted: trusted,
                             showDictionaries: {})
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return window
    }

    /// **The window read from outside, as VoiceOver reads it** (G7, 2026-10-18): a walk of the app's own views found no
    /// rows, since SwiftUI does not expose them to it, while `keys ax` from the stage found every one. Each reading
    /// writes `<work>/checkpoint-<name>.json` (this pid) and waits up to 15 s for the stage's `keys ax` answer in
    /// `checkpoint-<name>.ax.json` (`Tools/e2e.sh` `substage_setup`); no answer reads as an empty window, which fails.
    @MainActor
    final class WindowReader {
        let work: URL
        private var asked = 0
        private(set) var unanswered = 0

        init(work: URL) { self.work = work }

        func read() async -> [[String: Any]] {
            asked += 1
            let ask = work.appending(path: "checkpoint-setup-\(asked).json")
            let answer = work.appending(path: "checkpoint-setup-\(asked).ax.json")
            try? JSONSerialization.data(withJSONObject: ["pid": Int(getpid())]).write(to: ask, options: .atomic)
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                if let data = try? Data(contentsOf: answer), let nodes = SetupWindowReading.nodes(fromKeysAX: data) {
                    return nodes
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            unanswered += 1
            return []
        }

        /// The window's identifiers, once `wanted` is among them or after ten readings.
        func identifiers(waitingFor wanted: String) async -> Set<String> {
            var found: Set<String> = []
            for _ in 0..<10 {
                found = SetupWindowReading.identifiers(await read())
                if found.contains(wanted) { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
            return found
        }

        /// What a check's detail says about the readings: how many the stage never answered.
        var note: String { unanswered == 0 ? "" : "; \(unanswered) reading(s) the stage never answered" }
    }
}

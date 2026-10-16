import AppKit
import Foundation
import SwiftUI
import XDictAnywhere
import XDictClient
import XDictEntryView
import XDictInstruments
import XDictLibrary
import XDictUI

/// `XDict --setup-report <first|second> --library-dir <dir> --suite <name> --out <file>`: a development instrument for
/// the E2E `setup` stage (plan-macos-v1 WI-9, done-when; run on the E2E Mac only: it opens a window). **The production
/// setup board** over an empty library of its own, its rows read back through the window's own Accessibility tree:
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
        let usage = "\(flag) <first|second> --library-dir <dir> --suite <name> --out <file>"
        guard let phase = Instrument.value(after: flag, in: arguments), ["first", "second"].contains(phase),
              let directory = Instrument.value(after: "--library-dir", in: arguments).map(URL.init(fileURLWithPath:)),
              let suite = Instrument.value(after: "--suite", in: arguments),
              let defaults = UserDefaults(suiteName: suite),
              let out = Instrument.value(after: "--out", in: arguments).map(URL.init(fileURLWithPath:)) else {
            FileHandle.standardError.write(Data("usage: \(usage)\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            let library = Library(store: LibraryStore(directory: directory), backend: ServiceClient())
            await library.start()
            let findings = await (phase == "first" ? first(library: library, defaults: defaults)
                                                   : second(library: library, defaults: defaults, suite: suite))
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
    static func first(library: Library, defaults: UserDefaults) async -> Findings {
        var findings = Findings()
        let trust = HeldTrust()
        let window = show(library: library, trusted: { trust.check() })
        let before = await identifiers(in: window, waitingFor: "setup.accessibility.needed")
        findings.check("setup.rowsLive",
                       before.contains("setup.dictionaries.needed") && before.contains("setup.accessibility.needed")
                           && before.contains(where: { $0.hasPrefix("setup.shortcut.") }),
                       "rows on an empty library: \(before.filter { $0.hasPrefix("setup.") }.sorted())")
        trust.released = true
        let after = await identifiers(in: window, waitingFor: "setup.accessibility.done")
        findings.check("setup.grantCompletesRow", after.contains("setup.accessibility.done"),
                       "after the grant, without relaunch: \(after.filter { $0.hasPrefix("setup.accessibility") })")

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
    static func second(library: Library, defaults: UserDefaults, suite: String) async -> Findings {
        var findings = Findings()
        let accent = EntryPreferences(defaults: defaults).accent()
        let language = InterfaceLanguage.current(in: defaults, domain: suite)
        findings.check("setup.choicesPersist", accent == .indigo && language == .simplifiedChinese,
                       "after relaunch: accent \(accent.rawValue), language \(language.rawValue)")
        let window = show(library: library, trusted: { AccessibilityGate.system(false) })
        _ = await identifiers(in: window, waitingFor: "setup.dictionaries.needed")
        let english = texts(in: window.contentView).filter(Self.isEnglish)
        findings.check("setup.chineseOnly", english.isEmpty && Locale.preferredLanguages.first?.hasPrefix("zh") == true,
                       "languages \(Locale.preferredLanguages.prefix(2)); English left: \(english)")
        window.close()
        return findings
    }

    @MainActor
    static func show(library: Library, trusted: @escaping @MainActor () -> Bool) -> NSWindow {
        let view = SetupView(library: library, registrar: LookupAnywhere.shared.registrar, trusted: trusted,
                             openLibrary: {})
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return window
    }

    /// The window's Accessibility identifiers, once `wanted` is among them or after ten seconds.
    @MainActor
    static func identifiers(in window: NSWindow, waitingFor wanted: String) async -> Set<String> {
        var found: Set<String> = []
        for _ in 0..<100 {
            found = Set(elements(window.contentView).compactMap { $0.accessibilityIdentifier() }.filter { !$0.isEmpty })
            if found.contains(wanted) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return found
    }

    @MainActor
    static func elements(_ root: Any?) -> [NSAccessibilityElementProtocol & NSAccessibilityProtocol] {
        guard let element = root as? (NSAccessibilityElementProtocol & NSAccessibilityProtocol) else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap(elements)
    }

    @MainActor
    static func texts(in root: Any?) -> [String] {
        elements(root).flatMap { element in
            [element.accessibilityLabel(), element.accessibilityValue() as? String, element.accessibilityTitle()]
                .compactMap { $0 }.filter { !$0.isEmpty }
        }
    }

    /// A run of three Latin letters that is not one of the names XDict keeps in every language.
    static func isEnglish(_ text: String) -> Bool {
        var stripped = text
        for name in ["XDict", "MDict", "mdx", "mdd"] { stripped = stripped.replacingOccurrences(of: name, with: "") }
        return stripped.contains(/[A-Za-z]{3,}/)
    }
}

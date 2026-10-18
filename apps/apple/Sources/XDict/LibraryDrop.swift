import AppKit
import SwiftUI
import XDictClient
import XDictContract
import XDictInstruments
import XDictLibrary
import XDictUI
import XDictTokens

/// `XDict --library-drop <library-dir> --ready <file> --expect <file name>`: a development instrument for the E2E
/// `library` stage's drag-and-drop check (run on the E2E Mac only; never on the build Mac, whose screen is the
/// owner's). Shows the production Settings ▸ Dictionaries pane (`SettingsDictionaries`, ADR-0012 d.7: the Library
/// window is gone) over a library of its own, with a route of its own, in a window at a fixed place, and writes
/// `<file>` with the window's centre in global display points (origin top left, as `pointer` takes them) once it is on
/// screen. A real drag from elsewhere (`Tools/library/dragsource` and `pointer drag`) then drops a file on it; the
/// instrument prints `Findings` — whether a dictionary of that file name was registered and answers — and exits.
@MainActor
enum LibraryDropReport {
    static let flag = "--library-drop"
    /// Where the window stands: top left, in global points from the top left of the main display.
    static let frame = Tokens.InstrumentFrame.libraryDrop

    static func run(_ arguments: [String]) -> Never {
        guard let directory = Instrument.value(after: flag, in: arguments).map(URL.init(fileURLWithPath:)),
              let ready = Instrument.value(after: "--ready", in: arguments),
              let expect = Instrument.value(after: "--expect", in: arguments) else {
            Instrument.emit(Instrument.usage("\(flag) <library-dir> --ready <file> --expect <file name>"))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let library = Library(store: LibraryStore(directory: directory), backend: ServiceClient())
        let screen = NSScreen.main?.frame ?? .zero
        let window = NSWindow(contentRect: NSRect(x: frame.minX, y: screen.maxY - frame.maxY, width: frame.width,
                                                  height: frame.height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SettingsDictionaries(library: library, route: SettingsRoute()))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        app.activate()
        Task { @MainActor in
            await library.start()
            try? await Task.sleep(for: .seconds(1))
            let shown = window.frame
            // The table's own centre, not the window's: the strip and the problem box can push the table off the
            // window's centre (dark-en dropV3Mdd, 2026-10-18). No table, no drop: said, never aimed at by guess.
            guard let content = window.contentView, let aim = SettingsDictionaries.dropPoint(in: content) else {
                Instrument.emit(Instrument.usage("no dictionary table in the drop window to aim at"))
            }
            let centre = ["drop": [aim.x, aim.y], "window": [shown.minX, screen.maxY - shown.maxY,
                                                              shown.width, shown.height]]
            do {
                try JSONSerialization.data(withJSONObject: centre).write(to: URL(fileURLWithPath: ready), options: .atomic)
            } catch {
                Instrument.emit(Instrument.usage("the ready file could not be written: \(error)"))
            }
            let began = ContinuousClock.now
            var findings = Findings()
            while ContinuousClock.now - began < .seconds(90) {
                if let dropped = library.entries.first(where: { $0.mdx?.fileName == expect }),
                   library.phases[dropped.id] == .ready {
                    findings.check("drop.registered", true, "\(expect) was dropped, registered as \(dropped.displayName) "
                                   + "(\(dropped.edition?.rawValue.suffix(8) ?? "?")) and answers")
                    Instrument.emit(findings)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            findings.check("drop.registered", false, "nothing named \(expect) was registered within 90 s of a drag "
                           + "aimed at the table's centre (\(Int(aim.x)), \(Int(aim.y))); entries "
                           + "\(library.entries.map { "\($0.mdx?.fileName ?? "?"): \(String(describing: library.phases[$0.id]))" }), "
                           + "notices \(library.notices)")
            Instrument.emit(findings)
        }
        app.run()
        exit(1)
    }
}

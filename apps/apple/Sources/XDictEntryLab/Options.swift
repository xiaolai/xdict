import AppKit
import Foundation
import WebKit
import XDictEntryView

/// The lab's command line (`usage`). One mode per run; every path absolute; an unknown argument ends the run.
///
/// **`--disable-layer`** is the hostile suite's isolated per-layer control (plan-macos-v1 WI-4): it builds the entry
/// view without the named layers — `csp`, `rules`, `nav`, `popups`, `link-preconnect`, `peer-connection` — so the
/// suite can show an attempt leaving with a layer off and stopped with it on. It exists in this development
/// instrument alone; XDict.app has no such flag (`Tools/build-bundle.sh` refuses a bundle whose app carries the text).
struct LabOptions {
    enum Mode: Equatable {
        case hostile, faultSwitch(String), binding, reader, corpus, gallery, page
    }

    var mode: Mode?
    var fixture: URL?
    var twins: [URL] = []
    var cases: URL?
    var out: URL?
    var commands: URL?
    var sample: URL?
    var keys: URL?
    var persistence: String?
    var disabled: Set<String> = []
    /// The reader's "Original style" (ADR-0010 Q3) for the hostile battery's dictionary: the core renders it without the
    /// normalization and the view shows it without the frame, every layer of the confinement as it is.
    var originalStyle = false
    var concurrency = 4
    /// The gallery shows an even spread of this many sampled entries per dictionary instead of its three chosen.
    var spread = 0
    var only: Set<String> = []
    /// **`--style-dir`**: the gallery reads the reading style's files (`EntryStyle.names`) from this directory instead
    /// of the ones compiled into the entry view, so a style edit reaches a picture without a rebuild
    /// (`Tools/gallery/hot.sh`). The lab alone reads one; XDict.app compiles its style in, and `Tools/build-bundle.sh`
    /// refuses an app binary that holds this flag.
    var styleDir: URL?

    /// Printed with every mistake on the command line. Its text is also what `Tools/build-bundle.sh` looks for: the
    /// lab's binary must hold `--disable-layer` (the reading can see it) and the app's must not.
    static let usage = """
        usage:
          XDictEntryLab --hostile <fixture dir> --cases <cases.json> --out <report.json> [--disable-layer L,…] [--original-style]
                        [--concurrency N] [--only id,…]
          XDictEntryLab --fault-switch <fault> --fixture <dir> --out <report.json>
          XDictEntryLab --binding <twin-a dir> <twin-b dir> --out <report.json>
          XDictEntryLab --reader <fixture dir> --commands <dir> --out <report.json>
          XDictEntryLab --corpus <dir> --sample <sample.json> --out <report.json> [--persistence set|check]
          XDictEntryLab --gallery <dir> --sample <sample.json> --out <report.json> [--only dict,…] [--keys <earlier report.json>] [--spread n]
                        [--style-dir <dir>]
          XDictEntryLab --page <dir of dictionary folders> --out <report.json> [--only word,…]
        layers: csp, rules, nav, popups, link-preconnect, peer-connection, strip (the core's, not the view's)
        """

    static let layers: Set<String> = ["csp", "rules", "nav", "popups", "link-preconnect", "peer-connection", "strip"]
    static let faults: Set<String> = ["none", "missing-list", "missing-feature", "missing-setter", "missing-getter",
                                      "ineffective-setter"]

    static func parse(_ arguments: [String]) throws -> LabOptions {
        var options = LabOptions()
        var index = 1
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw LabFailure(description: "\(arguments[index - 1]) needs a value") }
            return arguments[index]
        }
        func path() throws -> URL { URL(fileURLWithPath: try value()) }
        while index < arguments.count {
            switch arguments[index] {
            case "--hostile": options.mode = .hostile; options.fixture = try path()
            case "--fault-switch": options.mode = .faultSwitch(try value())
            case "--fixture": options.fixture = try path()
            case "--binding": options.mode = .binding; options.twins = [try path(), try path()]
            case "--reader": options.mode = .reader; options.fixture = try path()
            case "--corpus": options.mode = .corpus; options.fixture = try path()
            case "--gallery": options.mode = .gallery; options.fixture = try path()
            case "--page": options.mode = .page; options.fixture = try path()
            case "--cases": options.cases = try path()
            case "--out": options.out = try path()
            case "--commands": options.commands = try path()
            case "--sample": options.sample = try path()
            case "--keys": options.keys = try path()
            case "--persistence": options.persistence = try value()
            case "--disable-layer":
                options.disabled.formUnion(try value().split(separator: ",").map(String.init))
            case "--original-style": options.originalStyle = true
            case "--spread": options.spread = max(0, Int(try value()) ?? 0)
            case "--concurrency": options.concurrency = max(1, Int(try value()) ?? 4)
            case "--style-dir": options.styleDir = try path()
            case "--only": options.only = Set(try value().split(separator: ",").map(String.init))
            default:
                // LaunchServices may add `-psn_…`, and `-NS…`/`-Apple…` pairs; anything else is a mistake.
                let argument = arguments[index]
                if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") { index += 1 }
                else if !argument.hasPrefix("-psn") {
                    throw LabFailure(description: "unknown argument \(argument)\n\(usage)")
                }
            }
            index += 1
        }
        let unknown = options.disabled.subtracting(layers)
        guard unknown.isEmpty else { throw LabFailure(description: "no layer called \(unknown.sorted())") }
        if case .faultSwitch(let fault) = options.mode, !faults.contains(fault) {
            throw LabFailure(description: "no fault called \(fault); the faults are \(faults.sorted())")
        }
        if options.styleDir != nil, options.mode != .gallery {
            throw LabFailure(description: "--style-dir is the gallery's alone")
        }
        guard options.mode != nil, options.out != nil else {
            throw LabFailure(description: "a mode and --out are needed\n\(usage)")
        }
        return options
    }

    /// The reading style the gallery renders with: the directory's files when `--style-dir` names one, every one of
    /// `EntryStyle.names` and no other, else the compiled one.
    func style() throws -> EntryStyle {
        guard let styleDir else { return .bundled }
        var texts: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: styleDir.path)
        where name.hasSuffix(".css") || name.hasSuffix(".js") {
            texts[name] = try String(contentsOf: styleDir.appending(path: name), encoding: .utf8)
        }
        return try EntryStyle(replacing: texts)
    }

    /// `strip` off: the lab's core applies no strip list (`Config.stripOffForTests`), so the view's own layers are proven
    /// against scripts, comments and the rest as written. The core's strip is a layer of the battery, never of the view: the app's service makes its
    /// core without it (`StripTests`).
    var stripOffForTests: Bool { disabled.contains("strip") }

    /// The entry view's confinement with the named layers off: `production` when none of the view's is.
    var confinement: EntryConfinement {
        let disabled = disabled.subtracting(["strip"])
        guard !disabled.isEmpty else { return .production }
        var features: [String] = []
        if !disabled.contains("link-preconnect") { features.append("LinkPreconnect") }
        if !disabled.contains("peer-connection") { features.append("PeerConnectionEnabled") }
        return EntryConfinement(policyHeader: !disabled.contains("csp"), ruleList: !disabled.contains("rules"),
                                navigationPolicy: !disabled.contains("nav"),
                                refusesNewWindows: !disabled.contains("popups"), featuresOff: features)
    }
}

/// WebKit's switches with one deliberate fault, to show the entry view refusing (ADR-0009 refutation, item 5).
@MainActor
struct FaultySwitches: WebKitFeatureSwitches {
    let real: PreferencesSwitches
    let fault: String

    func features() -> [String: AnyObject]? {
        guard fault != "missing-list", var all = real.features() else { return nil }
        if fault == "missing-feature" { all["LinkPreconnect"] = nil }
        return all
    }

    var canSet: Bool { fault != "missing-setter" && real.canSet }
    var canRead: Bool { fault != "missing-getter" && real.canRead }

    func setEnabled(_ enabled: Bool, _ feature: AnyObject) {
        // An ineffective setter: called, and nothing changes.
        guard fault != "ineffective-setter" else { return }
        real.setEnabled(enabled, feature)
    }

    func isEnabled(_ feature: AnyObject) -> Bool { real.isEnabled(feature) }
}

/// The opener the lab gives the entry view: it records, and opens nothing. The production opener hands the URL to the
/// default browser (`WorkspaceOpener`); the suite proves the call is made only after the reader's yes.
@MainActor
final class RecordingOpener: EntryURLOpener {
    private(set) var opened: [String] = []
    func open(_ url: URL) { opened.append(url.absoluteString) }
}

/// One JSON report, written whole or not at all.
enum Report {
    static func write(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let temporary = url.appendingPathExtension("tmp")
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    static func describe(_ event: EntryEvent) -> [String: Any] {
        var text = String(describing: event)
        if text.count > 600 { text = String(text.prefix(600)) + "…" }
        return ["t": Date().timeIntervalSince1970, "event": text]
    }

    static var webKitVersion: String {
        Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}

/// A plain titled window holding `view`, placed at `frame` (screen points) and shown without activating anything else.
@MainActor
func labWindow(_ title: String, frame: NSRect, view: NSView) -> NSWindow {
    let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = title
    window.contentView = view
    window.orderFrontRegardless()
    return window
}

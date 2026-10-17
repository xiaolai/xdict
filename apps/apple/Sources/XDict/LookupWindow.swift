import AppKit
import WebKit
import XDictClient
import XDictContract
import XDictEntryView
import XDictInstruments
import XDictLibrary
import XDictSearch
import XDictUI

/// `XDict --lookup-window <work> --fixtures <lookup> [--corpus <dir>]`: a development instrument for the E2E `lookup`
/// stage (run on the E2E Mac only; never on the build Mac, whose screen is the owner's). **The real app** — its main
/// window, its menus, its keyboard handling — over a library of its own in `<work>/store`, reaching its own service
/// through a `TransportHold`, so the checks can make one dictionary slow and one import last.
///
/// The driver (`Tools/lookup/drive.py`) talks to it through files in `<work>/commands`: `NNN.json` asks (`state`,
/// `front`, `run`, `quit`) and `NNN.out.json` answers. Once the library is set up it writes `ready.json`; the driver then
/// works the window with key events alone. Asked to `run`, it runs `LookupScenario` through the window's own model and
/// entry view; at each checkpoint it writes `checkpoint-<name>.json` with what the window must show then, and waits for
/// the driver's reading of the accessibility tree in `checkpoint-<name>.done.json`. Its findings go to
/// `<work>/findings.json`.
enum LookupWindowReport {
    static let flag = "--lookup-window"
    static let hold = TransportHold()

    /// The app's setup under this instrument: read by `XDictApp.setup` before anything else of the app is made.
    static func setup(_ arguments: [String]) -> AppSetup? {
        guard let work = Instrument.value(after: flag, in: arguments) else { return nil }
        return AppSetup(libraryDirectory: URL(fileURLWithPath: work).appending(path: "store"),
                        service: ServiceClient(connect: hold.connect(XPCServiceConnection.embedded)),
                        entryEvents: { event in LookupWindowRun.shared?.note(event) },
                        speechVolume: 0, speechSuite: InstrumentWindow.speechSuite)
    }

    /// Readies the run before the app starts: it begins when the first main window is made.
    @MainActor
    static func prepare(_ arguments: [String]) {
        guard let work = Instrument.value(after: flag, in: arguments).map(URL.init(fileURLWithPath:)),
              let fixtures = Instrument.value(after: "--fixtures", in: arguments).map(URL.init(fileURLWithPath:)) else {
            FileHandle.standardError.write(Data("usage: \(flag) <work> --fixtures <lookup> [--corpus <dir>] [--no-paging]\n".utf8))
            exit(2)
        }
        let corpus = Instrument.value(after: "--corpus", in: arguments).map(URL.init(fileURLWithPath:))
        let run = LookupWindowRun(work: work, fixtures: fixtures, corpus: corpus,
                                  paging: arguments.contains("--no-paging") ? .none : .firstPage)
        LookupWindowRun.shared = run
        XDictApp.windowMade = { state in run.windowMade(state) }
    }
}

/// One run of the instrument: the first main window, its scenario, and the driver's commands.
@MainActor
final class LookupWindowRun: LookupStage {
    static var shared: LookupWindowRun?
    /// Where checks read the page from: a world of their own, so the page's configuration is the production one.
    static let world = WKContentWorld.world(name: "xdict-lookup-check")

    let work: URL
    let fixtures: URL
    let corpus: URL?
    /// How much of the 66,355 records the scenario pages: the first page, for `ax.paging` (every record is walked by
    /// `LookupScenarioTests`, through the service); `--no-paging` leaves it out, for an E2E run without `lookup.paging`.
    let paging: LookupScenario.Paging
    var commands: URL { work.appending(path: "commands") }
    private var state: SearchWindowState?
    private var scenario: LookupScenario?
    private var setupFindings = Findings()
    private var answered: Set<String> = []
    private var running = false
    // What the entry view and the window said, for `landed` and the driver.
    private var requested: EntryReference?
    private var finished = false
    private var presentedSerial = -1
    private var keys: [[String: Any]] = []
    private var routed: [String] = []
    private var navigations: [String] = []
    /// Each change of the model's lookup, selection, entry shown and trail, and each landing waited for in vain, in
    /// order, for `<work>/timeline.json`: what a failed check's detail cannot say.
    private var timeline: [String] = []
    private let began = ContinuousClock.now

    init(work: URL, fixtures: URL, corpus: URL?, paging: LookupScenario.Paging) {
        self.work = work
        self.fixtures = fixtures
        self.corpus = corpus
        self.paging = paging
    }

    func note(_ event: EntryEvent) {
        switch event {
        case .documentRequested(let reference):
            requested = reference
            finished = false
        case .documentFinished:
            finished = true
        case .linkRouted(let url, let action):
            routed.append("\(action) \(url)")
        case .navigation(let url, let verdict, _, _):
            navigations.append("\(verdict) \(url)")
        default:
            break
        }
    }

    func windowMade(_ made: SearchWindowState) {
        guard state == nil else { return }
        state = made
        made.onPresented = { [weak self] shown, done in
            if done { self?.presentedSerial = max(self?.presentedSerial ?? -1, shown.serial) }
            self?.note("presented \(shown.result.entry.key)#\(shown.serial): \(done)")
        }
        watch(made.model)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.keys.append(["code": Int(event.keyCode), "mods": Int(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue),
                               "chars": event.charactersIgnoringModifiers ?? "", "active": NSApp.isActive,
                               "key": event.window != nil && event.window === self?.mainWindow])
            return event
        }
        Task { await self.begin(made) }
    }

    private func begin(_ made: SearchWindowState) async {
        try? FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        await LibraryLaunch.once()
        let scenario = LookupScenario(library: made.library, model: made.model, client: XDictApp.service,
                                      hold: LookupWindowReport.hold, stage: self, fixtures: fixtures,
                                      scratch: work.appending(path: "scratch"), corpus: corpus)
        self.scenario = scenario
        setupFindings = await scenario.setUp()
        write(["pid": Int(ProcessInfo.processInfo.processIdentifier), "setup": setupFindings.passed,
               "detail": setupFindings.checks.map(\.detail)], to: commands.appending(path: "ready.json"))
        while true {
            serve()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - The driver's commands

    private func serve() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: commands.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".json") && !name.contains(".out.") && !name.hasPrefix("checkpoint-")
            && name != "ready.json" && !answered.contains(name) {
            answered.insert(name)
            guard let data = FileManager.default.contents(atPath: commands.appending(path: name).path),
                  let asked = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let op = asked["op"] as? String else { continue }
            let out = commands.appending(path: name.replacingOccurrences(of: ".json", with: ".out.json"))
            switch op {
            case "state":
                write(snapshot(), to: out)
            case "pageFocus":
                Task { self.write(await self.pageFocus(), to: out) }
            case "front":
                NSApp.activate()
                mainWindow?.makeKeyAndOrderFront(nil)
                write(["asked": true], to: out)
            case "run":
                write(["started": !running], to: out)
                if !running {
                    running = true
                    Task { await self.runScenario() }
                }
            case "quit":
                write(["quitting": true], to: out)
                exit(0)
            default:
                write(["error": "no op \(op)"], to: out)
            }
        }
    }

    private func runScenario() async {
        guard let scenario else { return }
        note("the scenario begins")
        var findings = setupFindings
        if setupFindings.passed {
            findings.merge(await scenario.run(paging: paging))
            findings.merge(await supersededLoads())
            findings.merge(await originalStyleSwitch())
            findings.merge(await accentSwitch())
        }
        write(["timeline": timeline], to: work.appending(path: "timeline.json"))
        do {
            try findings.json().write(to: work.appending(path: "findings.json"), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("the findings could not be written: \(error)\n".utf8))
        }
    }

    // MARK: - A load replaced before WebKit asked about it

    static let supersedeRounds = 10

    /// `entry.supersededLoadIsNoLink` (the window only: there is no web view headless): the entry view asked for one
    /// entry and, before WebKit has asked about that load, another, ten times — as a reader's ↓ through the results
    /// can. WebKit still asks about each replaced load; that question must be dropped, not taken for the page following
    /// a link to the replaced entry's word (it was, 2026-10-15: the trail gained a link-mode place for the entry left).
    /// The documents are fetched first, so the second load follows the first at once; the check holds only if WebKit
    /// was seen asking about a replaced load at least once, so it cannot pass without the race it is about.
    private func supersededLoads() async -> Findings {
        var findings = Findings()
        let name = "entry.supersededLoadIsNoLink"
        guard let state, let alpha = state.model.known.first(where: { $0.name == "Alpha" }),
              let inner = ServiceEntryContent(source: alpha, backend: XDictApp.service) else {
            findings.check(name, false, "Alpha is not in the window's library")
            return findings
        }
        let pair = [EntryReference(key: "apple"), EntryReference(key: "banana")]
        var documents: [EntryReference: EntryDocument] = [:]
        for reference in pair { documents[reference] = try? await inner.entry(reference) }
        guard documents.count == pair.count else {
            findings.check(name, false, "Alpha's apple and banana could not be read: \(documents.keys.map(\.key))")
            return findings
        }
        let content = Prefetched(inner: inner, documents: documents)
        let model = state.model
        let (routedBefore, navigationsBefore, places, lookup) = (routed.count, navigations.count, model.trail.visits,
                                                                 model.lookup)
        // A pane of its own, made with the fetched documents: a pane keeps the content it was opened with.
        state.entry.closeEntry()
        var landed = 0
        for round in 0..<Self.supersedeRounds {
            let first = pair[round % 2], second = pair[(round + 1) % 2]
            _ = await state.entry.show(first, from: content)
            _ = await state.entry.show(second, from: content)
            let deadline = ContinuousClock.now + .seconds(5)
            while !(finished && requested == second && state.entry.reference == second), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if finished && state.entry.reference == second { landed += 1 }
        }
        // Any question still on its way is answered before the count.
        try? await Task.sleep(for: .milliseconds(500))
        let asked = navigations.dropFirst(navigationsBefore)
        let dropped = asked.filter { $0.hasPrefix("dropSuperseded") }.count
        let linked = Array(routed.dropFirst(routedBefore))
        findings.check(name, dropped > 0 && linked.isEmpty && landed == Self.supersedeRounds
                       && model.trail.visits == places && model.lookup == lookup,
                       "\(Self.supersedeRounds) pairs asked back to back, \(landed) second ones shown: WebKit asked "
                       + "about \(dropped) replaced load(s), each dropped; links routed: \(linked.prefix(4)); the trail "
                       + "\(model.trail.visits == places ? "unchanged" : "changed: \(places.count) → \(model.trail.visits.count) places"), "
                       + "the lookup \(model.lookup == lookup ? "unchanged" : "changed to \(model.lookup?.query ?? "none")"); "
                       + "questions: \(asked.prefix(6).map { String($0.prefix(60)) })")
        // The window's own entry again, from the window's own content.
        state.entry.closeEntry()
        if let shown = model.shown { await state.present(shown) }
        return findings
    }

    // MARK: - "Original style" (ADR-0010 Q3)

    /// `entry.originalStyleSwitch`: Alpha's "apple" (whose own `<style>` sets the page's margin, which the reading style
    /// drops) shown in the reading style, then the reader's "Original style" for Alpha switched on where the Library's
    /// switch keeps it (the window's preferences, under Alpha's lineage) and, with nothing else done, the entry shown
    /// again by the core without normalization and without XDict's frame: the page visibly not the same (the body's
    /// face and margin). Then off again, and the reading style back. The choice is left off.
    private func originalStyleSwitch() async -> Findings {
        var findings = Findings()
        let name = "entry.originalStyleSwitch"
        guard let state, let alpha = state.model.known.first(where: { $0.name == "Alpha" }),
              let content = ServiceEntryContent(source: alpha, backend: XDictApp.service,
                                                preferences: state.entry.preferences) else {
            findings.check(name, false, "Alpha is not in the window's library")
            return findings
        }
        let preferences = state.entry.preferences, key = alpha.preferencesKey
        defer { preferences.setOriginalStyle(false, for: key) }
        preferences.setOriginalStyle(false, for: key)
        state.entry.closeEntry()
        _ = await state.entry.show(EntryReference(key: "apple"), from: content)
        let look = #"""
            var b = document.body, s = b ? getComputedStyle(b) : null;
            var own = Array.from(document.querySelectorAll('style'))
              .some(function (e) { return /body\{margin:0\}/.test(e.textContent); });
            return JSON.stringify({frame: !!document.getElementById('xdict-frame-column'), own: own,
              font: s ? s.fontFamily : '', margin: s ? s.marginTop : '', text: b ? b.textContent.slice(0, 40) : ''});
            """#
        func read(until wanted: @escaping ([String: Any]) -> Bool) async -> [String: Any] {
            var last: [String: Any] = [:]
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if let text = await InstrumentPage.evaluate(state.entry.webView, look) as? String,
                   let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    last = parsed
                    if wanted(parsed) { return parsed }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return last
        }
        let showsApple = { (page: [String: Any]) in (page["text"] as? String)?.contains("apple") == true }
        let styled = await read { showsApple($0) && $0["frame"] as? Bool == true }
        preferences.setOriginalStyle(true, for: key)
        let original = await read { showsApple($0) && $0["frame"] as? Bool == false && $0["own"] as? Bool == true }
        preferences.setOriginalStyle(false, for: key)
        let back = await read { showsApple($0) && $0["frame"] as? Bool == true }
        let differs = styled["font"] as? String != original["font"] as? String
            || styled["margin"] as? String != original["margin"] as? String
        findings.check(name, styled["frame"] as? Bool == true && styled["own"] as? Bool == false
                       && original["frame"] as? Bool == false && original["own"] as? Bool == true && differs
                       && back["frame"] as? Bool == true && back["own"] as? Bool == false,
                       "reading style \(styled); original style \(original); back \(back)")
        state.entry.closeEntry()
        if let shown = state.model.shown { await state.present(shown) }
        return findings
    }

    // MARK: - The accent (Settings ▸ Reading)

    /// `entry.accentSwitch`: Alpha's "apple" open in the reading style; the accent preference set where Settings
    /// keeps it (its raw value under `EntryPreferences.accentKey`), red, then indigo, then teal, with nothing else
    /// done; each time the open entry's accent token turns to that accent's light or dark value (the pane redraws the
    /// entry it holds, as for any change of frame). The reader's earlier choice is put back.
    private func accentSwitch() async -> Findings {
        var findings = Findings()
        let name = "entry.accentSwitch"
        guard let state, let alpha = state.model.known.first(where: { $0.name == "Alpha" }),
              let content = ServiceEntryContent(source: alpha, backend: XDictApp.service,
                                                preferences: state.entry.preferences) else {
            findings.check(name, false, "Alpha is not in the window's library")
            return findings
        }
        let preferences = state.entry.preferences, before = preferences.accent()
        defer { preferences.setAccent(before) }
        preferences.setAccent(.teal)
        state.entry.closeEntry()
        _ = await state.entry.show(EntryReference(key: "apple"), from: content)
        let look = #"""
            var r = document.documentElement;
            return JSON.stringify({accent: getComputedStyle(r).getPropertyValue('--xdict-accent').trim().toLowerCase(),
              hue: r.getAttribute('data-xdict-hue') || '',
              text: document.body ? document.body.textContent.slice(0, 40) : ''});
            """#
        func read(until wanted: @escaping ([String: Any]) -> Bool) async -> [String: Any] {
            var last: [String: Any] = [:]
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if let text = await InstrumentPage.evaluate(state.entry.webView, look) as? String,
                   let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    last = parsed
                    if wanted(parsed) { return parsed }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return last
        }
        func shows(_ accent: EntryReadingFrame.Accent) -> ([String: Any]) -> Bool {
            { page in
                let value = page["accent"] as? String ?? ""
                return (page["text"] as? String)?.contains("apple") == true
                    && [accent.values.light, accent.values.dark].map { $0.lowercased() }.contains(value)
            }
        }
        let first = await read(until: shows(.teal))
        var pages = [("teal", first, shows(.teal)(first))]
        for accent in [EntryReadingFrame.Accent.red, .indigo, .teal] {
            preferences.setAccent(accent)
            let page = await read(until: shows(accent))
            pages.append((accent.rawValue, page, shows(accent)(page)))
        }
        findings.check(name, pages.allSatisfy(\.2),
                       pages.map { "\($0.0): \($0.1["accent"] ?? "?") hue \($0.1["hue"] ?? "?")" }.joined(separator: "; "))
        state.entry.closeEntry()
        if let shown = state.model.shown { await state.present(shown) }
        return findings
    }

    // MARK: - The timeline

    private func note(_ line: String) {
        let elapsed = ContinuousClock.now - began
        let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        timeline.append("\(milliseconds) \(line)")
        if timeline.count > 2000 { timeline.removeFirst(timeline.count - 2000) }
    }

    /// Notes the model each time its lookup, selection, entry shown or trail changes (once per turn of the run loop).
    private func watch(_ model: SearchModel) {
        withObservationTracking {
            _ = model.lookup
            _ = model.selection
            _ = model.shown
            _ = model.trail
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let lookup = model.lookup.map { "\($0.query)/\($0.mode == .reader ? "reader" : "link")" } ?? "none"
                let shown = model.shown.map { "\(model.source($0.result.dictionary)?.name ?? "?")/\($0.result.entry.key)#\($0.serial)" }
                let place = model.trail.current.map { "\($0.query)→\($0.result?.entry.key ?? "none")" } ?? "none"
                self.note("lookup \(lookup); selection \(model.selection?.entry.key ?? "none"); shown \(shown ?? "none"); "
                          + "trail \(model.trail.index)/\(model.trail.visits.count) at \(place); text \(model.text)")
                self.watch(model)
            }
        }
    }

    /// The page's own focus: the element the keyboard is in, as the page has it.
    private func pageFocus() async -> [String: Any] {
        guard let webView = state?.entry.webView else { return ["page": false] }
        let script = """
            const e = document.activeElement;
            return {hasFocus: document.hasFocus(), tag: e ? e.tagName : "", text: e ? (e.textContent || "").slice(0, 40) : "",
                    href: !!(e && e.hasAttribute("href"))};
            """
        guard let answer = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: Self.world),
              let page = answer as? [String: Any] else { return ["page": true, "read": false] }
        return page.merging(["page": true, "read": true]) { first, _ in first }
    }

    var mainWindow: NSWindow? { state?.entry.view.window }

    /// What the window holds now, for the driver.
    private func snapshot() -> [String: Any] {
        guard let state else { return ["window": false] }
        let model = state.model
        let scope: String = switch model.scope {
        case .all: "all"
        case .one(let id): model.source(id)?.name ?? "?"
        }
        let sections: [[String: Any]] = model.sections.map { section in
            var out: [String: Any] = ["name": section.name, "status": Self.kind(section.status)]
            if case .results(let results) = section.status { out["hits"] = results.hits.prefix(20).map(\.headword) }
            return out
        }
        var out: [String: Any] = [
            "window": true, "pid": Int(ProcessInfo.processInfo.processIdentifier), "active": NSApp.isActive,
            "mainIsKey": mainWindow?.isKeyWindow == true, "responder": responder(), "query": model.lookup?.query ?? "",
            "text": model.text, "mode": model.lookup.map { $0.mode == .reader ? "reader" : "link" } ?? "",
            "scope": scope, "sections": sections, "suggestions": model.listing?.headwords ?? [],
            "trailIndex": model.trail.index, "trailCount": model.trail.visits.count, "canGoBack": model.canGoBack,
            "canGoForward": model.canGoForward, "canReturnToOrigin": model.canReturnToOrigin, "keys": keys,
            "routed": routed, "entryFinished": finished, "findings": FileManager.default.fileExists(
                atPath: work.appending(path: "findings.json").path),
            "dictionaries": model.known.map(\.name),
        ]
        if let shown = model.shown {
            out["shown"] = ["dictionary": model.source(shown.result.dictionary)?.name ?? "?", "key": shown.result.entry.key,
                            "occurrence": Int(shown.result.entry.occurrence)]
        }
        out["resultLabels"] = model.sections.flatMap { section -> [String] in
            guard case .results(let results) = section.status else { return [] }
            let repeated = results.repeatedKeys
            return results.hits.prefix(20).map { hit in
                Self.label(hit, in: section.name, record: repeated.contains(hit.entry.key) ? Int(hit.entry.occurrence) + 1 : nil)
            }
        }
        return out
    }

    /// What has the keyboard: the search field, the results, the entry, or something else (named by its class).
    private func responder() -> String {
        guard let responder = mainWindow?.firstResponder else { return "none" }
        var view: NSView? = responder as? NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            view = field
        }
        var cursor = view
        while let current = cursor {
            if current is NSSearchField { return "search" }
            if current is WKWebView { return "entry" }
            if current is NSTableView || current is NSOutlineView { return "results" }
            cursor = current.superview
        }
        return "other:\(type(of: responder))"
    }

    static func kind(_ status: SectionStatus) -> String {
        switch status {
        case .searching: "searching"
        case .results: "results"
        case .noMatch: "noMatch"
        case .unavailable(let why): "unavailable:\(why)"
        case .failed(let why): "failed:\(why)"
        }
    }

    static func label(_ hit: Hit, in dictionary: String, record: Int?) -> String {
        String(localized: SearchSentences.result(headword: hit.headword, how: hit.how, record: record, dictionary: dictionary))
    }

    private func write(_ object: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - LookupStage

    func landed(_ shown: SearchModel.Shown) async -> Bool {
        let reference = EntryReference(key: shown.result.entry.key, occurrence: shown.result.entry.occurrence)
        let deadline = ContinuousClock.now + .seconds(15)
        while presentedSerial < shown.serial || requested != reference || !finished || state?.entry.reference != reference {
            guard ContinuousClock.now < deadline else {
                note("landing missed: \(reference.key)#\(shown.serial); presented #\(presentedSerial), requested "
                     + "\(requested?.key ?? "none"), finished \(finished), the view's \(state?.entry.reference?.key ?? "none")")
                return false
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    func scroll(to offset: Double) async -> Double? {
        guard let webView = state?.entry.webView else { return nil }
        _ = try? await webView.callAsyncJavaScript("window.scrollTo(0, y); return window.scrollY", arguments: ["y": offset],
                                                   in: nil, contentWorld: Self.world)
        try? await Task.sleep(for: .milliseconds(100))
        return await self.offset()
    }

    func offset() async -> Double? {
        await state?.entry.scrollOffset()
    }

    func checkpoint(_ name: String) async -> Findings {
        let file = commands.appending(path: "checkpoint-\(name).json")
        let done = commands.appending(path: "checkpoint-\(name).done.json")
        try? FileManager.default.removeItem(at: done)
        note("checkpoint \(name)")
        // A moment for SwiftUI to draw what the model now holds, as a reader would see it.
        try? await Task.sleep(for: .milliseconds(300))
        write(["name": name, "expect": expectations(name), "pid": Int(ProcessInfo.processInfo.processIdentifier)], to: file)
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            if let data = FileManager.default.contents(atPath: done.path),
               let answer = try? JSONDecoder().decode(Findings.self, from: data) {
                return answer
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        var findings = Findings()
        findings.check("ax.\(name)", false, "the driver never read the window at this checkpoint")
        return findings
    }

    /// What the window must show at a checkpoint, as VoiceOver reads it, since the Apple parity (2026-10-17): the
    /// list's first rows (the sidebar holds headwords, one each, P9); each dictionary that could not search, its sentence
    /// and next action, in the page; and the scope bar's choice. An entry `#id:text` is an element of that identifier
    /// with that text.
    private func expectations(_ name: String) -> [String: [String]] {
        guard let model = state?.model else { return [:] }
        if name == "suggestions" {
            // The keys beginning with the typed text are the list's rows.
            return ["present": Array(model.suggestions.prefix(5)), "absent": ["@take_box_000"], "ordered": []]
        }
        var present = Array((model.listing?.headwords ?? []).prefix(3))
        for section in model.sections {
            switch section.status {
            case .unavailable(.indexing), .results, .noMatch, .searching:
                continue
            case .unavailable, .failed:
                present.append(section.name)
                if let sentence = SearchSentences.status(section.status) { present.append(String(localized: sentence)) }
                if let next = section.next, SearchSentences.isButton(next) {
                    present.append(String(localized: SearchSentences.action(next)))
                }
            }
        }
        if case .one(let id) = model.scope, let source = model.source(id) {
            present.append("#scope:\(source.name)")
        } else {
            present.append("#scope:\(String(localized: "All"))")
        }
        return ["present": present, "absent": [], "ordered": []]
    }
}

/// An entry content whose documents were fetched beforehand, so the view can be asked for one right after another with
/// nothing to wait for between: everything else is the dictionary's own.
private struct Prefetched: EntryContent {
    let inner: any EntryContent
    let documents: [EntryReference: EntryDocument]

    var binding: EntryBinding { inner.binding }

    func entry(_ reference: EntryReference) async throws -> EntryDocument {
        if let document = documents[reference] { return document }
        return try await inner.entry(reference)
    }

    func resource(_ path: String) async throws -> EntryResource {
        try await inner.resource(path)
    }

    func link(_ url: String, origin: EntryLinkOrigin) async throws -> EntryLink {
        try await inner.link(url, origin: origin)
    }
}

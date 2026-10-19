import Foundation
import Testing
@testable import XDictEntryView

/// **The hover script against hostile pages, in a real web view** (verifier, 2026-10-19): `hover-word.js` installed as
/// every entry installs the shell's scripts (the shell's named world, document start, main frame only), asked through the
/// shell's own call (`EntryWebView.hoverText`), on synthetic pages written here. The web view is the development lab's
/// (`XDictEntryLab --hover-script`, built with the tests): in this runner a web view never starts loading. It is in no
/// window, and no page has a base URL or loads anything, so nothing is shown and nothing reaches the network.
///
/// What it must hold: **only rendered, visible text** — never `display: none`, `visibility: hidden` or `opacity: 0`
/// text, nor a `<script>`, `<style>`, `<template>` or `<noscript>`'s, for the word or for its sentence (`aria-hidden` is
/// not a reason: it hides from assistive technology, not from the eye); **the window cut on whole characters**; **its
/// own work bounded** — in depth, in nodes walked and in text taken, so 50 MB before the word or a 100,000-deep tree
/// costs a bounded time; and **the page's own changes to built-ins never reach it**.
struct HoverWordScriptTests {
    struct Page: Encodable {
        let name: String
        let body: String
        let target: String
        var offset: Int? = 1
        var max = 240
        /// "entry" for every script an entry installs (`EntryWebView.withEntryScripts`); the hover script alone otherwise.
        var scripts = "hover"
        /// A function body the lab runs on the loaded page, outside the shell's world; its string answer is reported.
        var probe: String?
        /// A function body the lab runs on the loaded page, outside the shell's world, to make a selection: the page is
        /// then asked for its selection (`EntryWebView.selectionText`) instead of the word under a point.
        var select: String?
        /// Whether the selection's page is asked for the text around it too.
        var sentence = true
    }

    struct Outcome: Sendable {
        let answer: EntryHoverText?
        /// A selection page's answer, as the shell takes it (`EntrySelectionText.validated`).
        var selection: EntrySelectionText?
        let milliseconds: Int
        /// From the page's load to its end, the shell's scripts' own work at load included.
        let loaded: Int
        let probe: String?
    }

    struct LabFailed: Error, CustomStringConvertible {
        let description: String
    }

    /// Everything the page can change in its own world — the script's own names, the built-ins it uses, the DOM's
    /// getters, `Object.prototype` — and a custom element's own `textContent`.
    static let overrides = """
        <script>
        window.__xdictHoverWord = function () { return {text: 'SPOOF', offset: 0, cutStart: false, cutEnd: false}; };
        window.XDictWordCore = { at: function () { return {word: 'SPOOF', start: 0, end: 1}; } };
        String.prototype.slice = function () { return 'SPOOFSLICE'; };
        String.prototype.substring = function () { return 'SPOOFSUB'; };
        Array.prototype.push = function () { throw new Error('page'); };
        Math.max = function () { return 1e9; }; Math.min = function () { return 1e9; };
        Range.prototype.toString = function () { return 'SPOOFRANGE'; };
        Range.prototype.getClientRects = function () { return [{left: -1e9, right: 1e9, top: -1e9, bottom: 1e9}]; };
        Document.prototype.caretRangeFromPoint = function () { throw new Error('page'); };
        window.getComputedStyle = function () { return {display: 'inline', visibility: 'visible', opacity: '1'}; };
        Object.defineProperty(Node.prototype, 'textContent', {get: function () { return 'SPOOFTEXT'; }});
        Object.defineProperty(Node.prototype, 'nodeValue', {get: function () { return 'SPOOFVALUE'; }});
        Object.defineProperty(CharacterData.prototype, 'data', {get: function () { return 'SPOOFDATA'; }});
        Intl.Segmenter = function () { throw new Error('page'); };
        Object.defineProperty(Object.prototype, 'cutEnd', {get: function () { return 'SPOOFCUT'; },
                                                           set: function () {}, configurable: true});
        class Evil extends HTMLElement { get textContent() { return 'EVILTEXT'; } }
        customElements.define('x-evil', Evil);
        </script>
        """

    /// A chain of `depth` spans under one more, built apart from the page and put in once, so the page's own building
    /// stays cheap.
    static func deep(_ depth: Int) -> String {
        "<div id=root></div><script>var head = document.createElement('span'), e = head;"
            + "for (var i = 0; i < \(depth); i++) { var s = document.createElement('span'); e.appendChild(s); e = s; }"
            + "e.id = 't'; e.textContent = 'Deep word here'; document.getElementById('root').appendChild(head);</script>"
    }

    /// The deepest element's depth below the root, and the reading frame's mark on the page's list (`lists()`), or
    /// "none" where the frame's passes did not run.
    static let listed = """
        var most = 0, all = document.getElementsByTagName('*');
        for (var i = 0; i < all.length; i++) { var d = 0; for (var a = all[i]; a; a = a.parentElement) d++; if (d > most) most = d; }
        return most + ' ' + (document.querySelector('ul').getAttribute('data-xdict-list') || 'none');
        """

    /// A click, and the milliseconds until the frame's reruns after it (50 and 400 ms later) are done.
    static let rerun = """
        var t = performance.now();
        document.dispatchEvent(new MouseEvent('click'));
        await new Promise(function (r) { setTimeout(r, 450); });
        await new Promise(function (r) { setTimeout(r, 0); });
        return String(Math.round(performance.now() - t));
        """

    static let pages: [Page] = [
        Page(name: "plain", body: "<p id=t>Quokka hover probe. Second sentence here.</p>", target: "t"),
        Page(name: "hidden-in-block",
             body: "<p id=t>Visible <span style='display:none'>HIDDENDISPLAY</span>"
                 + "<span style='visibility:hidden'>HIDDENVISIBILITY</span> <span style='opacity:0'>HIDDENOPACITY</span>"
                 + "word<style>.css-rule{color:red}</style><script>var SCRIPTTEXT=1</script> here."
                 + "<template>TEMPLATETEXT</template><noscript>NOSCRIPTTEXT</noscript> <span aria-hidden=true>Aria</span>"
                 + "<span hidden>HIDDENATTRIBUTE</span></p>",
             target: "t"),
        // The pointer in a block's padding, beside its text: the caret lands on the nearest word, the pointer is on none.
        Page(name: "beside-the-word", body: "<p id=t style='padding-left:200px'>Short</p>", target: "t", offset: nil),
        // A page may show its own scripts and styles: their text is still not the entry's, nor a text field's.
        Page(name: "unshown-made-visible",
             body: "<style>script, style, textarea { display: inline }</style>"
                 + "<p id=t>Before <script>var SCRIPTSHOWN = 1</script><style>.shown{}</style><textarea>AREATEXT</textarea>"
                 + " after</p>",
             target: "t"),
        // Text 3,000 elements deep beside the word, within the walk's steps: past the depth read, so not read.
        Page(name: "deep-beside",
             body: "<p id=b><span id=t>Near words</span></p><script>var head = document.createElement('span'), e = head;"
                 + "for (var i = 0; i < 3000; i++) { var s = document.createElement('span'); e.appendChild(s); e = s; }"
                 + "e.textContent = ' DEEPTEXT'; document.getElementById('b').appendChild(head);</script>",
             target: "t"),
        // `content-visibility: hidden` lays its box out and skips its contents: they are as hidden as under display none.
        Page(name: "content-visibility-hidden",
             body: "<p id=t>Shown words <span style='display:inline-block;content-visibility:hidden'>CVHIDDEN</span>"
                 + " after</p>",
             target: "t"),
        Page(name: "visibility-hidden-word",
             body: "<p><span id=t style='visibility:hidden'>Concealed</span> words here visible</p>", target: "t"),
        Page(name: "opacity-zero-word",
             body: "<p><span id=t style='opacity:0'>Transparent</span> words here visible</p>", target: "t"),
        Page(name: "opacity-zero-above-block", body: "<div style='opacity:0'><p id=t>Faded words</p></div>", target: "t"),
        Page(name: "visible-in-hidden-block",
             body: "<p style='visibility:hidden'><span id=t style='visibility:visible'>Shown</span> hidden rest</p>",
             target: "t"),
        Page(name: "no-block-script",
             body: "<span id=t>Loose words</span><script>var PAGESOURCE = 'Loose source';</script>", target: "t"),
        Page(name: "pair-at-start",
             body: "<p id=t>&#x1D49C;&#x1D49C;&#x1D49C;&#x1D49C;&#x1D49C; word &#x1D49C;&#x1D49C;&#x1D49C;&#x1D49C;</p>",
             target: "t", offset: 12, max: 5),
        Page(name: "combining-at-start", body: "<p id=t>e&#x301;e&#x301;e&#x301; word</p>", target: "t", offset: 8, max: 4),
        Page(name: "pair-at-end", body: "<p id=t>word &#x1D49C;&#x1D49C;&#x1D49C;</p>", target: "t", offset: 1, max: 6),
        Page(name: "fifty-megabytes-before",
             body: "<p id=b></p><script>var p = document.getElementById('b');"
                 + "p.appendChild(document.createTextNode('x '.repeat(25000000)));"
                 + "var s = document.createElement('span'); s.id = 't'; s.textContent = 'target word end'; p.appendChild(s);"
                 + "</script>",
             target: "t", max: 1_000),
        Page(name: "fifty-megabytes-around",
             body: "<p id=b></p><script>var p = document.getElementById('b'); p.id = 't';"
                 + "p.appendChild(document.createTextNode('quokka '.repeat(7200000)));</script>",
             target: "t", max: 1_000),
        Page(name: "deep-40", body: deep(40), target: "t"),
        Page(name: "deep-100000", body: deep(100_000), target: "t"),
        // Every script an entry installs, on a tree a page script nests 10,000 deep, and on one the parser nests.
        Page(name: "entry-deep-10000", body: "<ul><li>Listed</li></ul>" + deep(10_000), target: "t", scripts: "entry",
             probe: listed),
        // The same, each element marked as a sense, as the core marks roles: the frame's rerun after a click (`later()`)
        // spaces every role-marked block, asking each one's ancestors.
        Page(name: "entry-deep-roles-10000",
             body: "<div id=root></div><script>var head = document.createElement('span'), e = head;"
                 + "for (var i = 0; i < 10000; i++) { var s = document.createElement('div');"
                 + "s.setAttribute('data-xdict-role', 'sense'); e.appendChild(s); e = s; }"
                 + "e.id = 't'; e.textContent = 'Deep word here'; document.getElementById('root').appendChild(head);</script>",
             target: "t", scripts: "entry", probe: rerun),
        Page(name: "entry-parsed-600", body: "<ul><li>Listed</li></ul>" + String(repeating: "<span>", count: 600)
                 + "<b id=t>Parsed deep words</b>", target: "t", scripts: "entry", probe: listed),
        Page(name: "empty-flood",
             body: "<p id=b></p><script>var p = document.getElementById('b');"
                 + "var f = document.createDocumentFragment();"
                 + "for (var i = 0; i < 100000; i++) f.appendChild(document.createElement('span'));"
                 + "var s = document.createElement('span'); s.id = 't'; s.textContent = 'Last words'; f.appendChild(s);"
                 + "p.appendChild(f);"
                 + "</script>",
             target: "t"),
        Page(name: "shadow",
             body: "<div id=t style='width:300px;height:60px'></div><script>"
                 + "document.getElementById('t').attachShadow({mode: 'open'}).innerHTML = '<p>Shadow words here</p>';</script>",
             target: "t", offset: nil),
        Page(name: "iframe",
             body: "<iframe id=t style='width:300px;height:60px;border:0' srcdoc='<p>Framed words here</p>'></iframe>",
             target: "t", offset: nil),
        Page(name: "input", body: "<input id=t value='Field words here' style='width:300px'>", target: "t", offset: nil),
        Page(name: "textarea", body: "<textarea id=t style='width:300px;height:60px'>Area words here</textarea>",
             target: "t", offset: nil),
        Page(name: "overrides", body: overrides + "<p id=t>Quokka hover probe sentence here.</p>", target: "t"),
        Page(name: "custom-element", body: overrides + "<p><x-evil id=t>Quokka inside a custom element.</x-evil></p>",
             target: "t"),
    ]

    /// The lab beside this test bundle, run once over every page.
    static let outcomes: Result<[String: Outcome], LabFailed> = run()

    private final class Marker {}

    /// Runs `path` with `arguments`, its output into `log` (never a pipe nobody drains while it runs), no input, only the
    /// environment it needs, **responsible for itself**: launched as the runner's child, the lab's web view never
    /// finished loading a page (measured 2026-10-19, three runs; run from a shell it loads at once). Bounded: a lab still
    /// running after a minute is ended, and its status is the signal's.
    private static func spawn(_ path: String, _ arguments: [String], log: String) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_spawnattrs_setdisclaim") else {
            throw LabFailed(description: "responsibility_spawnattrs_setdisclaim is missing")
        }
        _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let inherited = ProcessInfo.processInfo.environment
        let environment = ["HOME", "PATH", "TMPDIR", "USER", "LOGNAME"].compactMap { name in
            inherited[name].map { "\(name)=\($0)" }
        }
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard spawned == 0 else { throw LabFailed(description: "posix_spawn failed: \(spawned)") }
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(60)
        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() > deadline {
                // SIGKILL: an app whose main thread waits on its web view answers SIGTERM only when that wait ends.
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Exited: its code; ended by a signal: the signal's number, as negative.
        return status & 0x7f == 0 ? (status >> 8) & 0xff : -(status & 0x7f)
    }

    private static func run() -> Result<[String: Outcome], LabFailed> {
        let lab = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "XDictEntryLab")
        guard FileManager.default.isExecutableFile(atPath: lab.path) else {
            return .failure(LabFailed(description: "no lab at \(lab.path): it is built with the tests"))
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "xdict-hover-script-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let cases = folder.appending(path: "pages.json"), out = folder.appending(path: "report.json")
            try JSONEncoder().encode(pages + selectionPages).write(to: cases)
            let log = folder.appending(path: "lab.log")
            let status = try spawn(lab.path, ["--hover-script", "--cases", cases.path, "--out", out.path], log: log.path)
            guard status == 0 else {
                let said = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                return .failure(LabFailed(description: "the lab ended \(status): \(said.suffix(2_000))"))
            }
            let report = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any]
            var found: [String: Outcome] = [:]
            for item in report?["cases"] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String, let milliseconds = item["milliseconds"] as? Int,
                      let loaded = item["loaded"] as? Int else { continue }
                // Checked again as the shell checks it: JSON keeps a boolean a boolean.
                let answer = (item["answer"] as? [String: Any]).flatMap { EntryHoverText.validated($0, maxUTF16: 4_096) }
                let selection = EntrySelectionText.validated(item["selection"], maxUTF16: 4_096)
                found[name] = Outcome(answer: answer, selection: selection, milliseconds: milliseconds, loaded: loaded,
                                      probe: item["probe"] as? String)
            }
            return .success(found)
        } catch {
            return .failure(LabFailed(description: "\(error)"))
        }
    }

    func outcome(_ name: String) throws -> Outcome {
        let all = try Self.outcomes.get()
        return try #require(all[name], "no outcome for \(name)")
    }

    /// Not throwing, so a failed expectation shows the answer: a page with no outcome is an issue of its own, and answers
    /// a text no page gives.
    private func answer(_ name: String) -> EntryHoverText? {
        do { return try outcome(name).answer } catch {
            Issue.record(error)
            return EntryHoverText(text: "no outcome", offset: -1, cutStart: true, cutEnd: true)
        }
    }

    private func text(_ text: String, _ offset: Int, cut: (Bool, Bool) = (false, false)) -> EntryHoverText {
        EntryHoverText(text: text, offset: offset, cutStart: cut.0, cutEnd: cut.1)
    }

    /// Every page answered within the bound, the giants included.
    @Test func everyPageAnswersWithinASecond() throws {
        for page in Self.pages {
            let took = try outcome(page.name).milliseconds
            #expect(took < 1_000, "\(page.name): \(took) ms")
        }
    }

    // MARK: - Rendered text only

    @Test func aPlainSentenceIsReadWhole() throws {
        #expect(answer("plain") == text("Quokka hover probe. Second sentence here.", 0))
    }

    /// Hidden text inside the word's block is not part of its sentence: `display: none` (and `hidden`), `visibility:
    /// hidden`, `opacity: 0`, a `<style>`, a `<script>`, a `<template>`, a `<noscript>`. `aria-hidden` text is shown.
    @Test func hiddenTextIsNoPartOfTheSentence() throws {
        #expect(answer("hidden-in-block") == text("Visible  word here. Aria", 0))
        #expect(answer("unshown-made-visible") == text("Before  after", 0), "a script, a style or a field made visible")
        #expect(answer("content-visibility-hidden") == text("Shown words  after", 0), "content-visibility: hidden")
        // The walk runs out of steps climbing back from the deep text, so the end may be cut.
        #expect(answer("deep-beside") == text("Near words", 0, cut: (false, true)), "text deeper than the script reads")
    }

    /// The word under the pointer never comes from hidden text: laid out, so the caret finds it, but not seen.
    @Test func hiddenTextIsNeverTheWord() throws {
        #expect(answer("visibility-hidden-word") == nil)
        #expect(answer("opacity-zero-word") == nil)
        #expect(answer("opacity-zero-above-block") == nil)
        #expect(answer("visible-in-hidden-block") == text("Shown", 0), "a visible child of a hidden block, alone")
    }

    /// With no block between the word and the body, the body is the block — and the page's script source is not text.
    @Test func thePagesScriptIsNeverTheSentence() throws {
        #expect(answer("no-block-script") == text("Loose words", 0))
    }

    // MARK: - Whole characters

    /// 𝒜 is two UTF-16 units, é here a letter and a combining accent: a window that would start or end inside one
    /// moves to the next whole character.
    @Test func theWindowIsCutOnWholeCharacters() throws {
        #expect(answer("pair-at-start") == text(" wor", 1, cut: (true, true)))
        #expect(answer("combining-at-start") == text(" wo", 1, cut: (true, true)))
        #expect(answer("pair-at-end") == text("word ", 0, cut: (false, true)))
    }

    // MARK: - Bounded work

    /// 50 MB of text before the word: only what the window needs is taken.
    @Test func fiftyMegabytesBeforeTheWordAreNotWalked() throws {
        #expect(answer("fifty-megabytes-before")
                == text(String(String(repeating: "x ", count: 493).dropFirst()) + "target word end", 985, cut: (true, false)))
    }

    /// A word inside one 50 MB text node: segmented and windowed around the word, never the whole node.
    @Test func aWordInsideFiftyMegabytesIsWindowed() throws {
        #expect(answer("fifty-megabytes-around")
                == text(String(String(repeating: "quokka ", count: 143).prefix(1_000)), 0, cut: (false, true)))
    }

    /// A tree deeper than the script reads is given up, and one well within it is read.
    @Test func aTreeTooDeepIsGivenUp() throws {
        #expect(answer("deep-40") == text("Deep word here", 0))
        #expect(answer("deep-100000") == nil)
    }

    /// 100,000 empty elements before the word: the walk stops at its own bound and says the start may be cut.
    @Test func aFloodOfEmptyElementsStopsTheWalk() throws {
        #expect(answer("empty-flood") == text("Last words", 0, cut: (true, false)))
    }

    // MARK: - The entry's own scripts on a deep page

    /// **No pass of the reading frame reads a tree nested past what the HTML parser builds** (2026-10-19: with every
    /// script an entry installs, a page script's 100,000-deep tree had not loaded in 28 minutes; the frame's `spacing()`
    /// asks each element's ancestors, so its cost grew with the square of the depth: 7.0 s at 10,000). A page the
    /// parser builds is nested at most 512 deep, and its frame still runs.
    @Test func theReadingFrameSkipsATreeNoParserBuilds() throws {
        let deep = try outcome("entry-deep-10000")
        #expect(deep.loaded < 2_000, "\(deep.loaded) ms")
        #expect(deep.probe == "10004 none")
        let roles = try outcome("entry-deep-roles-10000")
        #expect(roles.loaded < 2_000, "\(roles.loaded) ms")
        let rerun = try #require(roles.probe.flatMap { Int($0) }, "no rerun time")
        #expect(rerun < 1_000, "the frame's rerun after a click: \(rerun) ms")
        let parsed = try outcome("entry-parsed-600")
        #expect(parsed.probe == "512 marked")
    }

    // MARK: - Out of reach

    @Test func textOutsideTheDocumentsOwnTextIsNotRead() throws {
        for name in ["shadow", "iframe", "input", "textarea"] {
            #expect(answer(name) == nil, "\(name)")
        }
    }

    @Test func aPointerBesideTheWordReadsNothing() throws {
        #expect(answer("beside-the-word") == nil)
    }

    // MARK: - Isolation

    /// None of the page's changes reaches the shell's world.
    @Test func thePagesBuiltInsNeverReachTheScript() throws {
        #expect(answer("overrides") == text("Quokka hover probe sentence here.", 0))
        #expect(answer("custom-element") == text("Quokka inside a custom element.", 0))
    }
}

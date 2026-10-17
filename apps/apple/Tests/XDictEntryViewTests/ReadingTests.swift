import AppKit
import Foundation
import JavaScriptCore
import Testing
@testable import XDictEntryView

/// **What the reader does with an entry**: follows a link, answers the remote-link question, finds, zooms, picks an
/// appearance, opens the context menu. The shell's scripts' pure parts run in JavaScriptCore; no web view is made.
@MainActor
struct ReadingTests {
    // MARK: - Links

    @Test func eachLinkGoesWhereItsKindSays() throws {
        let remote = try #require(URL(string: "https://example.com/a"))
        let rows: [(EntryLink, Bool, EntryLinkAction)] = [
            (.lookup(query: "walk", anchor: "s2"), true, .lookup(query: "walk", anchor: "s2")),
            (.lookup(query: "walk", anchor: nil), false, .lookup(query: "walk", anchor: nil)),
            (.anchor(name: "s2"), true, .scroll(anchor: "s2")),
            (.sound(path: "us/run.mp3"), true, .sound(path: "us/run.mp3")),
            (.speak(text: "run"), true, .speak(text: "run")),
            (.blocked(.remote(url: "https://example.com/a")), true, .askReader(remote)),
        ]
        for (link, activated, action) in rows {
            #expect(EntryLinkAction.for(link, activatedByALink: activated) == action)
        }
        // Nothing, but said why: a remote URL a script reached without a link, one no browser opens, a script, a
        // resource, an unknown scheme.
        let nothing: [(EntryLink, Bool)] = [
            (.blocked(.remote(url: "https://example.com/a")), false),
            (.blocked(.remote(url: "ftp://example.com/a")), true),
            (.blocked(.remote(url: "https://user:pw@example.com/")), true),
            (.blocked(.script), true),
            (.blocked(.unknownScheme("tel")), true),
            (.resource(path: "a.css"), true),
        ]
        for (link, activated) in nothing {
            #expect(EntryLinkAction.for(link, activatedByALink: activated).name == "nothing", "\(link)")
        }
    }

    // MARK: - The reader's consent

    final class Opener: EntryURLOpener {
        var opened: [URL] = []
        func open(_ url: URL) { opened.append(url) }
    }

    @Test func onlyAYesOpensAndOnlyOneQuestionAtATime() throws {
        let gate = RemoteOpenGate()
        let first = try #require(URL(string: "https://example.com/a"))
        let second = try #require(URL(string: "https://example.org/b"))
        #expect(gate.request(first) == .ask(first, host: "example.com"))
        // A page activating links in a loop raises one question, not a stack.
        guard case .drop = gate.request(second) else {
            Issue.record("a second question was raised while the first was asked")
            return
        }
        #expect(gate.answer(consent: false) == nil)
        #expect(gate.asking == nil)
        #expect(gate.request(second) == .ask(second, host: "example.org"))
        #expect(gate.answer(consent: true) == second)
        // An answer with no question opens nothing.
        #expect(gate.answer(consent: true) == nil)
    }

    @Test func onlyAWebAddressIsEverOffered() {
        for text in ["https://example.com/", "http://example.com:8080/a?b#c", "HTTPS://Example.COM/"] {
            #expect(RemoteOpenGate.openable(text) != nil, "\(text)")
        }
        for text in ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/", "https:///nohost",
                     "https://u:p@example.com/", "xdict://d/r/a", "mailto:a@example.com", "not a url"] {
            #expect(RemoteOpenGate.openable(text) == nil, "\(text)")
        }
    }

    // MARK: - Find (R3)

    static func context(_ sources: String...) throws -> JSContext {
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, value in failure = value?.toString() }
        for source in sources { context.evaluateScript(source) }
        if let failure { Issue.record("script failed: \(failure)") }
        return context
    }

    static func matches(_ text: String, _ query: String, in context: JSContext) -> [[Int]] {
        let value = context.objectForKeyedSubscript("XDictFindCore")?.invokeMethod("matches", withArguments: [text, query])
        return (value?.toArray() as? [[NSNumber]])?.map { $0.map(\.intValue) } ?? [[-1]]
    }

    @Test func findCountsEveryMatchWhateverItsCaseAndSpacing() throws {
        let context = try Self.context(EntryScripts.findCore)
        #expect(Self.matches("Hold, hold on; HOLD.", "hold", in: context) == [[0, 4], [6, 10], [15, 19]])
        #expect(Self.matches("hold\n  on and hold on", "hold on", in: context) == [[0, 9], [14, 21]])
        #expect(Self.matches("a.b axb", "a.b", in: context) == [[0, 3]], "a query is text, not a pattern")
        #expect(Self.matches("(1) [2] $3 ^4", "[2] $3", in: context) == [[4, 10]])
        #expect(Self.matches("Ärger ärger", "ÄRGER", in: context).count == 2)
        #expect(Self.matches("取得 取得", "取得", in: context).count == 2)
        #expect(Self.matches("aaa", "aa", in: context) == [[0, 2]], "matches do not overlap")
        #expect(Self.matches("anything", "   ", in: context).isEmpty)
        #expect(Self.matches("anything", "", in: context).isEmpty)
    }

    /// The DOM half needs a document, which only the E2E Mac gives it; here it must at least be a script that parses,
    /// and that touches nothing when run with no document.
    @Test func theDocumentScriptsParse() throws {
        let context = try Self.context("var parsed = [];")
        for (name, source) in [("findDOM", EntryScripts.findDOM), ("placeholderClicks", EntryScripts.placeholderClicks),
                               ("disclosureDOM", EntryScripts.disclosureDOM),
                               ("appearance light", EntryScripts.appearance(.light)),
                               ("appearance dark", EntryScripts.appearance(.dark))] {
            context.setObject(source, forKeyedSubscript: "source" as NSString)
            let parsed = context.evaluateScript("try { new Function(source); 'ok' } catch (e) { String(e) }")
            #expect(parsed?.toString() == "ok", "\(name)")
        }
    }

    /// XDict's speaker answers whatever the page does with clicks: COBUILD's own script cancels a click on its sound
    /// links (it plays them itself, from an `addr` XDict never serves), so the click never reached the router and four
    /// of its recordings went unanswered (E2E 2026-10-16: "clicked, cancelled by the page"). The shell's listener, on
    /// the window in the capture phase and installed before any page script, stops the click going further into the
    /// page and leaves its default, the navigation the router answers, alone. Any other click is the page's.
    @Test func aSpeakersClickIsXDictsNotThePages() throws {
        #expect(EntryScripts.installed(.light, frame: .all).contains(EntryScripts.speakerClicks))
        let context = try Self.context("""
            var listeners = [];
            var window = { addEventListener: function (type, f, capture) { listeners.push([type, f, capture]); } };
            var document = window;
            function click(isSpeaker) {
              var e = { stopped: false, prevented: false, isTrusted: true,
                target: { closest: function (s) { return isSpeaker && s.indexOf('data-xdict-control') >= 0 ? {} : null; } },
                stopImmediatePropagation: function () { this.stopped = true; },
                stopPropagation: function () { this.stopped = true; },
                preventDefault: function () { this.prevented = true; } };
              listeners.forEach(function (l) { if (l[0] === 'click') l[1](e); });
              return [e.stopped, e.prevented];
            }
            """, EntryScripts.speakerClicks)
        #expect(context.evaluateScript("JSON.stringify(listeners.map(function (l) { return [l[0], l[2]]; }))")?.toString()
                == #"[["click",true]]"#)
        #expect(context.evaluateScript("JSON.stringify(click(true))")?.toString() == "[true,false]")
        #expect(context.evaluateScript("JSON.stringify(click(false))")?.toString() == "[false,false]")
    }

    @Test func noShellScriptMakesARequestOrChangesTheURL() {
        let all = [EntryScripts.findCore, EntryScripts.findDOM, EntryScripts.readabilityCore,
                   EntryScripts.appearance(.dark), EntryScripts.placeholderClicks, EntryScripts.speakerClicks]
            .joined(separator: "\n")
        for word in ["fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "location", "window.open",
                     "import(", "Worker(", ".src =", ".href =", "RTCPeerConnection"] {
            #expect(!all.contains(word), "a shell script uses \(word)")
        }
    }

    // MARK: - Readability (R4)

    /// The gallery's contrast arithmetic: a measurement, nothing on the page is corrected by it.
    @Test func contrastIsWCAGs() throws {
        let context = try Self.context(EntryScripts.readabilityCore)
        func run(_ expression: String) -> JSValue? { context.evaluateScript(expression) }
        #expect(run("XDictReadability.contrast([0,0,0],[255,255,255])")?.toDouble() ?? 0 > 20.9)
        #expect(run("XDictReadability.parse('rgba(1, 2, 3, 0.5)').join()")?.toString() == "1,2,3,0.5")
        #expect(run("XDictReadability.parse('rgb(1 2 3 / 50%)').join()")?.toString() == "1,2,3,0.5")
        #expect(run("XDictReadability.parse('color(srgb 1 0 0)')")?.isNull == true, "an unknown form is left alone")
    }

    @Test func eachThemeDrawsAsItSays() {
        #expect(EntryTheme.matchApp.scheme(appIsDark: true) == .dark)
        #expect(EntryTheme.matchApp.scheme(appIsDark: false) == .light)
        #expect(EntryTheme.original.scheme(appIsDark: true) == .light)
        #expect(EntryTheme.dark.scheme(appIsDark: false) == .dark)
        #expect(Set(EntryTheme.allCases.map { String(localized: EntrySentences.theme($0)) }).count == 3)
    }

    // MARK: - Text size, one for every dictionary (Apple parity P29); appearance per dictionary (R4)

    /// Since the Apple parity (owner, 2026-10-17) the text size is one, for every dictionary, as Apple's Dictionary
    /// has it; it was per dictionary (ADR-0010 d.3). The appearance stays per dictionary.
    @Test func textSizeIsOneForEveryDictionaryAndThemeIsKeptPerDictionary() throws {
        let suite = "xdict-entry-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EntryPreferences(defaults: defaults)
        #expect(preferences.zoom() == 1.0)
        #expect(preferences.theme(for: "a") == .matchApp)
        preferences.setZoom(1.25)
        preferences.setTheme(.original, for: "a")
        #expect(preferences.zoom() == 1.25)
        #expect(preferences.theme(for: "a") == .original)
        #expect(preferences.theme(for: "b") == .matchApp)
        // Read again through a new instance, as after a relaunch.
        #expect(EntryPreferences(defaults: defaults).zoom() == 1.25)
        preferences.setZoom(40)
        #expect(preferences.zoom() == 3.0)
        defaults.set(-2.0, forKey: EntryPreferences.zoomKey)
        defaults.set("neon", forKey: EntryPreferences.themeKey("c"))
        #expect(preferences.zoom() == 1.0)
        #expect(preferences.theme(for: "c") == .matchApp)
    }

    /// **P30**: Apple's find look: the page dimmed while there are matches, each match white, the current one yellow
    /// (`findHighlightColor`, #ffff00).
    @Test func findDrawsMatchesAsApplesFindDoes() {
        let find = EntryStyle.bundled.script("find.js")
        #expect(find.contains("::highlight(xdict-find-current){background-color:#ffff00"))
        #expect(find.contains("::highlight(xdict-find){background-color:#ffffff"))
        #expect(find.contains("xdict-finding"), "the page is not dimmed while finding")
        #expect(!find.contains("#ff9632") && !find.contains("#ffe36e"))
        #expect(find.contains("selection: function") && find.contains("jump: function"), "⌘E and ⌘J have nothing to ask")
    }

    /// The accent (Settings ▸ Reading): teal unless chosen, kept across launches, teal for a value it does not know;
    /// the reading frame carries it, Original style's does not.
    @Test func theAccentIsKeptAndCarriedByTheFrame() throws {
        let suite = "xdict-entry-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EntryPreferences(defaults: defaults)
        #expect(preferences.accent() == .teal)
        preferences.setAccent(.indigo)
        #expect(EntryPreferences(defaults: defaults).accent() == .indigo)
        defaults.set("neon", forKey: EntryPreferences.accentKey)
        #expect(preferences.accent() == .teal)
        #expect(EntryReadingFrame.all.accent == .teal)
        #expect(EntryReadingFrame.all.with(accent: .red).accent == .red)
        #expect(EntryReadingFrame.all.with(accent: .red).with(accent: .teal) == .all)
        #expect(EntryReadingFrame.all.applied(originalStyle: true).with(accent: .red) == .minimal)
        let script = EntryScripts.appearance(.dark, frame: EntryReadingFrame.all.with(accent: .indigo))
        #expect(script.contains("HUE = 'indigo'"))
        #expect(script.contains(":root[data-xdict-theme=dark][data-xdict-hue=indigo]{--xdict-accent:#c4c1ff}"))
        #expect(EntryReadingFrame.paletteCSS.contains(":root[data-xdict-theme=light]{") && EntryReadingFrame.paletteCSS.contains("--xdict-accent:#055959;"))
    }

    @Test func zoomStepsWalkTheLadder() {
        #expect(EntryPreferences.step(1.0, up: true) == 1.1)
        #expect(EntryPreferences.step(1.0, up: false) == 0.9)
        #expect(EntryPreferences.step(1.05, up: true) == 1.1)
        #expect(EntryPreferences.step(3.0, up: true) == 3.0)
        #expect(EntryPreferences.step(0.5, up: false) == 0.5)
    }

    // MARK: - The context menu

    @Test func theMenuKeepsOnlyWhatKeepsTheReaderHere() {
        let menu = NSMenu()
        func item(_ id: String?) -> NSMenuItem {
            let made = NSMenuItem(title: id ?? "Untitled", action: nil, keyEquivalent: "")
            made.identifier = id.map { NSUserInterfaceItemIdentifier(rawValue: $0) }
            return made
        }
        for entry: NSMenuItem in [item("WKMenuItemIdentifierOpenLinkInNewWindow"), item("WKMenuItemIdentifierDownloadLinkedFile"),
                                  .separator(), item("WKMenuItemIdentifierCopy"), item("WKMenuItemIdentifierCopyLink"),
                                  .separator(), .separator(), item("WKMenuItemIdentifierOpenImageInNewWindow"),
                                  item("WKMenuItemIdentifierDownloadImage"), item("WKMenuItemIdentifierLookUp"),
                                  item(nil), .separator(), item("WKMenuItemIdentifierShareMenu"),
                                  item("WKMenuItemIdentifierSpeechMenu"), .separator()] {
            menu.addItem(entry)
        }
        let (kept, removed) = EntryMenu.filter(menu)
        #expect(kept == ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierSpeechMenu"])
        #expect(removed.count == 7)
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : ($0.identifier?.rawValue ?? "") }
                == ["WKMenuItemIdentifierCopy", "-", "WKMenuItemIdentifierLookUp", "-", "WKMenuItemIdentifierSpeechMenu"])
    }
}

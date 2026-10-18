import AppKit
import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import XDictEntryView

/// **A dictionary's display options in the entry view** (ADR-0013 decisions 3, 4 and 7): the reader's choice is stored
/// as intent per lineage and resolved against what the shown edition declares; the core's CSS is installed with the
/// entry, and the root attribute is always set from the shell's own world, the default included, so an entry that writes
/// the attribute itself cannot choose for the reader. A change applies to the shown entry without fetching it again.
@MainActor
struct DisplayOptionsTests {
    static let pronunciation = EntryDisplayOption(id: "pronunciation", attribute: "data-xdict-opt-pronunciation",
                                                  values: ["respell", "ipa", "both"], defaultValue: "ipa")
    static let css = #":root[data-xdict-opt-pronunciation="respell"] .t_IPA { display: none !important; }"#

    static func preferences() throws -> (EntryPreferences, UserDefaults, String) {
        let suite = "xdict.display.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (EntryPreferences(defaults: defaults), defaults, suite)
    }

    // MARK: - What the service says, held to the catalogue's shape

    /// An option is taken only in the shape the core writes: a plain id, its attribute `data-xdict-opt-<id>`, plain
    /// values, no repeats, its default among them. Anything else never reaches a page.
    @Test func anOptionIsTakenOnlyInTheCataloguesShape() throws {
        let option = try #require(Self.pronunciation)
        #expect(option.id == "pronunciation" && option.defaultValue == "ipa")
        #expect(EntryDisplayOption(id: "pronunciation", attribute: "data-xdict-opt-other", values: ["a"],
                                   defaultValue: "a") == nil, "an attribute not its own id's")
        #expect(EntryDisplayOption(id: "p\"x", attribute: "data-xdict-opt-p\"x", values: ["a"], defaultValue: "a") == nil)
        #expect(EntryDisplayOption(id: "p", attribute: "data-xdict-opt-p", values: ["a b"], defaultValue: "a b") == nil)
        #expect(EntryDisplayOption(id: "p", attribute: "data-xdict-opt-p", values: ["a", "a"], defaultValue: "a") == nil)
        #expect(EntryDisplayOption(id: "p", attribute: "data-xdict-opt-p", values: ["a", "b"], defaultValue: "c") == nil)
        #expect(EntryDisplayOption(id: "p", attribute: "data-xdict-opt-p", values: [], defaultValue: "") == nil)
    }

    // MARK: - d.4: intent, per lineage, resolved against the edition

    @Test func noStoredChoiceMeansTheEditionsDefault() throws {
        let (preferences, defaults, suite) = try Self.preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let option = try #require(Self.pronunciation)
        #expect(preferences.storedDisplayChoice("pronunciation", for: "lineage-a") == nil)
        #expect(preferences.displayChoice(option, for: "lineage-a") == "ipa")
    }

    @Test func aStoredChoiceIsPerLineage() throws {
        let (preferences, defaults, suite) = try Self.preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let option = try #require(Self.pronunciation)
        preferences.setDisplayChoice("respell", option: "pronunciation", for: "lineage-a")
        #expect(preferences.displayChoice(option, for: "lineage-a") == "respell")
        #expect(preferences.displayChoice(option, for: "lineage-b") == "ipa", "another lineage's choice leaked")
        #expect(defaults.string(forKey: EntryPreferences.displayChoiceKey("pronunciation", "lineage-a")) == "respell")
    }

    /// A stored value the edition does not declare stays stored and is inactive: the edition's default shows, and the
    /// intent comes back when an edition that declares the value does.
    @Test func aStoredValueTheEditionDoesNotDeclareIsKeptAndInactive() throws {
        let (preferences, defaults, suite) = try Self.preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let narrower = try #require(EntryDisplayOption(id: "pronunciation", attribute: "data-xdict-opt-pronunciation",
                                                       values: ["ipa", "both"], defaultValue: "both"))
        preferences.setDisplayChoice("respell", option: "pronunciation", for: "lineage-a")
        #expect(preferences.displayChoice(narrower, for: "lineage-a") == "both")
        #expect(preferences.storedDisplayChoice("pronunciation", for: "lineage-a") == "respell", "the intent was lost")
        #expect(preferences.displayChoice(try #require(Self.pronunciation), for: "lineage-a") == "respell")
    }

    /// Every declared option gets a value, the default included: what the page's root is given.
    @Test func everyDeclaredOptionHasAValueTheDefaultIncluded() throws {
        let (preferences, defaults, suite) = try Self.preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let options = EntryDisplayOptions(options: [try #require(Self.pronunciation)], css: Self.css)
        #expect(preferences.displayValues(options, for: "lineage-a")
            == [EntryDisplayValue(attribute: "data-xdict-opt-pronunciation", value: "ipa")])
        #expect(preferences.displayValues(.none, for: "lineage-a").isEmpty)
    }

    // MARK: - d.3: the root attribute, from the shell's world

    /// A document as the script sees one, with no DOM: a root that takes attributes, `head`, and the readiness event.
    static let fakeDocument = """
        var window = this;
        var root = { attrs: {}, children: [],
          setAttribute: function (n, v) { this.attrs[n] = String(v); },
          getAttribute: function (n) { return Object.prototype.hasOwnProperty.call(this.attrs, n) ? this.attrs[n] : null; },
          appendChild: function (c) { c.isConnected = true; this.children.push(c); return c; } };
        var listeners = {};
        var document = { readyState: 'loading', documentElement: root, head: null,
          createElement: function (t) { return { tagName: t, textContent: '', isConnected: false }; },
          getElementById: function () { return null; },
          addEventListener: function (n, f) { listeners[n] = f; } };
        """

    static func script(_ value: String) throws -> String {
        let options = EntryDisplayOptions(options: [try #require(pronunciation)], css: css)
        return try #require(EntryScripts.display(options, values: [EntryDisplayValue(attribute: "data-xdict-opt-pronunciation",
                                                                                     value: value)]))
    }

    /// The default is written too, and the core's CSS goes in with it.
    @Test func theAttributeIsSetEvenToTheDefaultWithTheCSS() throws {
        let context = try ReadingTests.context(Self.fakeDocument, try Self.script("ipa"))
        #expect(context.evaluateScript("root.getAttribute('data-xdict-opt-pronunciation')")?.toString() == "ipa")
        #expect(context.evaluateScript("root.children.length")?.toInt32() == 1)
        #expect(context.evaluateScript("root.children[0].tagName")?.toString() == "style")
        #expect(context.evaluateScript("root.children[0].textContent")?.toString() == Self.css)
    }

    /// **A hostile entry writes the attribute itself** (`<html data-xdict-opt-pronunciation="respell">`, or a script
    /// before the document is ready): the shell's value is set at document start and set again when the document is
    /// ready, so the entry's never stands.
    @Test func anEntrysOwnAttributeDoesNotStand() throws {
        let context = try ReadingTests.context(
            Self.fakeDocument, "root.setAttribute('data-xdict-opt-pronunciation', 'respell');", try Self.script("ipa"))
        #expect(context.evaluateScript("root.getAttribute('data-xdict-opt-pronunciation')")?.toString() == "ipa")
        context.evaluateScript("root.setAttribute('data-xdict-opt-pronunciation', 'respell'); listeners.DOMContentLoaded();")
        #expect(context.evaluateScript("root.getAttribute('data-xdict-opt-pronunciation')")?.toString() == "ipa")
        #expect(context.evaluateScript("root.children.length")?.toInt32() == 1, "the CSS was installed twice")
    }

    /// A change reaches the shown document in place: the attribute is set again, the CSS left as it was.
    @Test func aChangeIsSetInPlace() throws {
        let context = try ReadingTests.context(Self.fakeDocument, try Self.script("ipa"))
        let read = context.evaluateScript(
            "window.__xdictDisplay.set([['data-xdict-opt-pronunciation', 'both']])")?.toArray() as? [String]
        #expect(read == ["both"])
        #expect(context.evaluateScript("root.getAttribute('data-xdict-opt-pronunciation')")?.toString() == "both")
        #expect(context.evaluateScript("root.children.length")?.toInt32() == 1)
    }

    /// No option, no script: a dictionary that declares nothing gets nothing new in its page.
    @Test func noOptionsNoScript() throws {
        #expect(EntryScripts.display(.none, values: []) == nil)
    }

    // MARK: - The view

    static func shown(declaring options: EntryDisplayOptions, choice: String? = nil) async throws
        -> (EntryViewController, EntryPreferences, EventRecorder, UserDefaults, String) {
        let (preferences, defaults, suite) = try Self.preferences()
        if let choice { preferences.setDisplayChoice(choice, option: "pronunciation", for: "lineage-alpha") }
        var environment = EntryEnvironment(preferences: preferences)
        environment.ruleListDirectory = FileManager.default.temporaryDirectory
            .appending(path: "xdict-display-rules-\(UUID().uuidString)")
        let recorder = EventRecorder()
        environment.events = { recorder.events.append($0) }
        let controller = EntryViewController(environment: environment)
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let content = FakeContent("alpha")
        content.display = options
        content.documents["alpha"] = EntryDocument(html: Data("<html data-xdict-opt-pronunciation=\"respell\"><b>alpha</b>".utf8),
                                                   policy: "default-src 'none'")
        _ = await controller.show(EntryReference(key: "alpha"), from: content)
        return (controller, preferences, recorder, defaults, suite)
    }

    static func displayScripts(_ controller: EntryViewController) -> [WKUserScript] {
        (controller.webView?.configuration.userContentController.userScripts ?? [])
            .filter { $0.source.contains("__xdictDisplay") }
    }

    /// The shown entry's page is given the attribute, the default included, at document start, in the shell's world.
    @Test func theShownEntryIsGivenTheEffectiveValueAtDocumentStart() async throws {
        let options = EntryDisplayOptions(options: [try #require(Self.pronunciation)], css: Self.css)
        let (controller, _, _, defaults, suite) = try await Self.shown(declaring: options)
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        let scripts = Self.displayScripts(controller)
        #expect(scripts.count == 1)
        #expect(scripts.first?.injectionTime == .atDocumentStart)
        #expect(scripts.first?.isForMainFrameOnly == true)
        #expect(scripts.first?.source.contains(#"["data-xdict-opt-pronunciation","ipa"]"#) == true,
                "\(scripts.first?.source.prefix(200) ?? "none")")
    }

    /// A dictionary that declares nothing gets no display script.
    @Test func aDictionaryDeclaringNothingGetsNoScript() async throws {
        let (controller, _, _, defaults, suite) = try await Self.shown(declaring: .none)
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(controller.webView != nil)
        #expect(Self.displayScripts(controller).isEmpty)
    }

    /// **A change applies live**: the shown document is set in place and the next load starts with the new value; the
    /// entry is not asked for again.
    @Test func aChangeAppliesWithoutFetchingTheEntryAgain() async throws {
        let options = EntryDisplayOptions(options: [try #require(Self.pronunciation)], css: Self.css)
        let (controller, preferences, recorder, defaults, suite) = try await Self.shown(declaring: options, choice: "both")
        defer {
            controller.closeEntry()
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(Self.displayScripts(controller).first?.source.contains(#"["data-xdict-opt-pronunciation","both"]"#) == true)
        let requested = recorder.requested
        controller.setDisplayChoice("respell", option: "pronunciation")
        #expect(preferences.storedDisplayChoice("pronunciation", for: "lineage-alpha") == "respell")
        #expect(Self.displayScripts(controller).first?.source.contains(#"["data-xdict-opt-pronunciation","respell"]"#) == true)
        #expect(recorder.requested == requested && requested == 1, "the entry was fetched again")
        #expect(controller.displayValues == [EntryDisplayValue(attribute: "data-xdict-opt-pronunciation", value: "respell")])
    }
}

@MainActor
final class EventRecorder {
    var events: [EntryEvent] = []
    /// How many times an entry was asked of the dictionary.
    var requested: Int { events.filter { if case .documentRequested = $0 { true } else { false } }.count }
}

import AppKit
import Foundation
import Testing
import WebKit
@testable import XDictEntryView

/// **The layers outside the page**: the rule list, the navigation table, the two WebKit switches and the gate that makes
/// no web view unless every layer holds (ADR-0009 decision 7; refutation item 5). No web view is made here: the gate is
/// tested on its own, and `EntryPane.open` only on the paths that must refuse.
@MainActor
struct ConfinementTests {
    // MARK: - The rule list

    @Test func theRuleListBlocksEverythingThenLiftsOnlyItsOwnSpace() throws {
        let decoded = try JSONSerialization.jsonObject(with: Data(try EntryRuleList.encoded().utf8)) as? [[String: [String: String]]]
        let rules = try #require(decoded)
        #expect(rules.first?["trigger"]?["url-filter"] == ".*")
        #expect(rules.first?["action"]?["type"] == "block")
        let lifted = rules.dropFirst().map { $0["trigger"]?["url-filter"] ?? "" }
        #expect(lifted == ["^xdict://d/", "^data:", "^blob:", "^about:"])
        #expect(rules.dropFirst().allSatisfy { $0["action"]?["type"] == "ignore-previous-rules" })
        // No rule lifts a remote scheme, whatever its spelling.
        for remote in ["http", "https", "ws", "wss", "ftp", "file"] {
            #expect(!lifted.contains { $0.contains(remote) }, "\(remote) is let through")
        }
    }

    /// WebKit compiles it: the JSON is the syntax WebKit takes, not only well-formed. Compiling makes no web view.
    @Test func webKitCompilesTheRuleList() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "xdict-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let list = try await EntryRuleList.compile(in: directory)
        #expect(list.identifier == EntryRuleList.identifier)
    }

    // MARK: - The navigation table

    static let shown = URL(string: "xdict://d/entry/run")
    static func facts(_ url: String?, main: Bool? = true, kind: EntryNavigationPolicy.Kind = .linkActivated,
                      download: Bool = false, pending: URL? = nil, current: URL? = shown) -> EntryNavigationPolicy.Facts {
        EntryNavigationPolicy.Facts(url: url.flatMap(URL.init(string:)), targetIsMainFrame: main, kind: kind,
                                    download: download, pendingDocument: pending, currentDocument: current)
    }

    @Test func theNavigationTable() throws {
        let remote = try #require(URL(string: "https://example.com/a"))
        let rows: [(EntryNavigationPolicy.Facts, EntryNavigationPolicy.Verdict)] = [
            // 1. A download, even of the view's own document.
            (Self.facts("xdict://d/entry/run", kind: .other, download: true, pending: Self.shown), .refuse(.download)),
            (Self.facts(nil), .refuse(.noURL)),
            // 2. Frames the page writes itself.
            (Self.facts("about:blank", main: false, kind: .other), .allowFrameOfItsOwn),
            (Self.facts("about:srcdoc", main: false, kind: .other), .allowFrameOfItsOwn),
            // 3. The document being loaded, in the main frame only.
            (Self.facts("xdict://d/entry/run", kind: .other, pending: Self.shown, current: nil), .loadDocument),
            (Self.facts("xdict://d/entry/run", main: false, kind: .other, pending: Self.shown, current: nil),
             .route("xdict://d/entry/run")),
            // 4. A fragment of the shown document.
            (Self.facts("xdict://d/entry/run#sense-2"), .allowSameDocument),
            (Self.facts("xdict://d/entry/walk#sense-2"), .route("xdict://d/entry/walk#sense-2")),
            // 5. Anything else of the view's own: routed, in any frame, by any means, and as a new window.
            (Self.facts("xdict://d/entry/walk"), .route("xdict://d/entry/walk")),
            (Self.facts("xdict://d/r/page.html", main: false, kind: .other), .route("xdict://d/r/page.html")),
            (Self.facts("xdict://d/r/pic.svg", kind: .other), .route("xdict://d/r/pic.svg")),
            (Self.facts("xdict://d/sound/run.mp3"), .route("xdict://d/sound/run.mp3")),
            (Self.facts("xdict://d/blocked/https%3A%2F%2Fexample.com"), .route("xdict://d/blocked/https%3A%2F%2Fexample.com")),
            (Self.facts("xdict://d/entry/walk", main: nil), .route("xdict://d/entry/walk")),
            // 6. Remote: the reader is asked only when a link was activated.
            (Self.facts("https://example.com/a"), .askReader(remote)),
            (Self.facts("https://example.com/a", main: nil), .askReader(remote)),
            (Self.facts("https://example.com/a", kind: .other), .refuse(.remoteNotActivatedByALink)),
            (Self.facts("http://example.com/a", kind: .formSubmitted), .refuse(.remoteNotActivatedByALink)),
            (Self.facts("wss://example.com/a", main: false, kind: .other), .refuse(.remoteNotActivatedByALink)),
            (Self.facts("http://127.0.0.1:47090/a", kind: .reload), .refuse(.remoteNotActivatedByALink)),
            // 7. Every other scheme.
            (Self.facts("data:text/html,x"), .refuse(.otherScheme)),
            (Self.facts("blob:xdict://d/1"), .refuse(.otherScheme)),
            (Self.facts("javascript:alert(1)"), .refuse(.otherScheme)),
            (Self.facts("file:///etc/passwd"), .refuse(.otherScheme)),
            (Self.facts("mailto:a@example.com"), .refuse(.otherScheme)),
            (Self.facts("xdict://e/entry/run"), .refuse(.otherScheme)),
            (Self.facts("xdict://d:1/entry/run", pending: URL(string: "xdict://d:1/entry/run")), .refuse(.otherScheme)),
        ]
        for (facts, verdict) in rows {
            #expect(EntryNavigationPolicy.decide(facts) == verdict, "\(facts.url?.absoluteString ?? "nil")")
        }
        #expect(rows.filter { $0.1.allows }.count == 4)
    }

    @Test func onlyItsOwnResponsesAreShown() {
        #expect(EntryNavigationPolicy.responseAllowed(url: URL(string: "xdict://d/entry/run"), canShowMIMEType: true))
        #expect(EntryNavigationPolicy.responseAllowed(url: URL(string: "about:srcdoc"), canShowMIMEType: true))
        #expect(!EntryNavigationPolicy.responseAllowed(url: URL(string: "xdict://d/r/a.zip"), canShowMIMEType: false))
        #expect(!EntryNavigationPolicy.responseAllowed(url: URL(string: "https://example.com/"), canShowMIMEType: true))
        #expect(!EntryNavigationPolicy.responseAllowed(url: nil, canShowMIMEType: true))
    }

    // MARK: - The switches

    @Test func bothSwitchesAreTurnedOffAndReadBack() {
        let switches = FakeSwitches()
        #expect(EntrySwitches.turnOff(on: switches) == .success(["LinkPreconnect": false, "PeerConnectionEnabled": false]))
        #expect(switches.sets == ["LinkPreconnect=false", "PeerConnectionEnabled=false"])
        #expect(switches.listed?["Other"] == true, "a switch not asked for was touched")
    }

    /// **Each fault refuses on its own, with its own sentence** (refutation item 5): the list, a feature, the setter, the
    /// getter, and a setter that does nothing.
    @Test func eachMissingOrIneffectivePartRefuses() {
        func refusal(_ fault: (FakeSwitches) -> Void) -> EntryRefusal? {
            let switches = FakeSwitches()
            fault(switches)
            guard case .failure(let why) = EntrySwitches.turnOff(on: switches) else { return nil }
            return why
        }
        let refusals: [EntryRefusal?] = [
            refusal { $0.listed = nil },
            refusal { $0.listed?["PeerConnectionEnabled"] = nil },
            refusal { $0.canSet = false },
            refusal { $0.canRead = false },
            refusal { $0.setterWorks = false },
        ]
        #expect(refusals == [
            .switchMissing("+[WKPreferences _features]"),
            .switchMissing("PeerConnectionEnabled"),
            .switchMissing("-[WKPreferences _setEnabled:forFeature:]"),
            .switchUnverifiable("-[WKPreferences _isEnabledForFeature:]"),
            .switchStillOn("LinkPreconnect"),
        ])
        let sentences = refusals.compactMap { $0 }.map { String(localized: EntrySentences.refusal($0)) }
        #expect(Set(sentences).count == 5, "two faults read as one sentence")
        #expect(sentences.allSatisfy { !$0.isEmpty })
    }

    /// A feature missing from the list is found before anything is set: nothing is half turned off.
    @Test func aMissingFeatureSetsNothing() {
        let switches = FakeSwitches()
        switches.listed?["PeerConnectionEnabled"] = nil
        _ = EntrySwitches.turnOff(on: switches)
        #expect(switches.sets.isEmpty)
    }

    /// This Mac's WebKit, through the SPI: both switches exist, turn off and read back off. No web view is made.
    @Test func thisMacsWebKitHasBothSwitches() {
        #expect(EntryReadiness.check() == .success(["LinkPreconnect": false, "PeerConnectionEnabled": false]))
        let switches = PreferencesSwitches(WKPreferences())
        #expect(switches.canSet && switches.canRead)
        #expect(switches.features()?.keys.contains("LinkPreconnect") == true)
    }

    /// The real WebKit, asked for a feature it does not have: refused by name, the injected name the sentence's.
    @Test func aFeatureThisWebKitLacksIsRefusedByName() {
        let missing = "XDictNoSuchFeature"
        let result = EntrySwitches.turnOff(["LinkPreconnect", missing], on: PreferencesSwitches(WKPreferences()))
        #expect(result == .failure(.switchMissing(missing)))
        #expect(String(localized: EntrySentences.refusal(.switchMissing(missing))).contains(missing))
    }

    // MARK: - The gate before any web view

    @Test func theGateRequiresTheRuleListAndTheSwitches() {
        let production = EntryConfinement.production
        #expect(EntryPane.gate(production, switches: FakeSwitches(), ruleList: nil)
                == .failure(.ruleListUnavailable("the rule list was not compiled")))
        #expect(EntryPane.gate(production, switches: FakeSwitches(), ruleList: .failure(.ruleListUnavailable("x")))
                == .failure(.ruleListUnavailable("x")))
        let noRules = EntryConfinement(policyHeader: true, ruleList: false, navigationPolicy: true, refusesNewWindows: true,
                                       featuresOff: EntrySwitches.required)
        #expect(EntryPane.gate(noRules, switches: FakeSwitches(), ruleList: nil)
                == .success(["LinkPreconnect": false, "PeerConnectionEnabled": false]))
        let broken = FakeSwitches()
        broken.setterWorks = false
        #expect(EntryPane.gate(noRules, switches: broken, ruleList: nil) == .failure(.switchStillOn("LinkPreconnect")))
    }

    /// **A refusal makes no web view**, so nothing can load: `open` is given a maker that counts, and every fault leaves
    /// it at zero.
    @Test func aRefusedGateMakesNoWebView() {
        final class Host: EntryPaneHost {
            var events: [EntryEvent] = []
            func record(_ event: EntryEvent) { events.append(event) }
            func perform(_ action: EntryLinkAction, from pane: EntryPane) {}
            func askReader(_ url: URL, from pane: EntryPane) {}
            func newWindow(_ configuration: WKWebViewConfiguration, for action: WKNavigationAction) -> WKWebView? { nil }
            func documentFinished(_ pane: EntryPane) {}
        }
        let noRules = EntryConfinement(policyHeader: true, ruleList: false, navigationPolicy: true, refusesNewWindows: true,
                                       featuresOff: EntrySwitches.required)
        let faults: [(EntryConfinement, (FakeSwitches) -> Void)] = [
            (.production, { _ in }), // no rule list compiled
            (noRules, { $0.listed = nil }),
            (noRules, { $0.listed?["LinkPreconnect"] = nil }),
            (noRules, { $0.canSet = false }),
            (noRules, { $0.canRead = false }),
            (noRules, { $0.setterWorks = false }),
        ]
        var made = 0
        for (confinement, fault) in faults {
            let result = EntryPane.open(content: FakeContent("a"), confinement: confinement, scheme: .light, ruleList: nil,
                                        switches: { _ in let s = FakeSwitches(); fault(s); return s }, host: Host(),
                                        makeWebView: { made += 1; return EntryWebView(frame: .zero, configuration: $0) })
            guard case .failure = result else {
                Issue.record("a pane was opened past a fault")
                continue
            }
        }
        #expect(made == 0)
    }

    @Test func theAppsConfinementIsEveryLayer() {
        let production = EntryConfinement.production
        #expect(production.policyHeader && production.ruleList && production.navigationPolicy && production.refusesNewWindows)
        #expect(production.featuresOff == ["LinkPreconnect", "PeerConnectionEnabled"])
        #expect(production.isProduction)
        #expect(EntryEnvironment().confinement.isProduction, "the default environment is not the production one")
        let lacking = EntryConfinement(policyHeader: false, ruleList: true, navigationPolicy: true, refusesNewWindows: true,
                                       featuresOff: EntrySwitches.required)
        #expect(!lacking.isProduction)
    }
}

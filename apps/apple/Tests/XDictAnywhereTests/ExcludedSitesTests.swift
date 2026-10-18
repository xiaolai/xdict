import Foundation
import Testing
import XDictAnywhere
import XDictCapture

@MainActor
private func hover(_ defaults: UserDefaults? = nil) throws -> HoverControl {
    let suite = try defaults ?? #require(UserDefaults(suiteName: "ai.xdict.tests.sites.\(UUID().uuidString)"))
    return HoverControl(defaults: suite, requests: CaptureRequests(), screen: CountedScreen().access,
                        source: SilentPointerWords())
}

/// **The sites hover never reads, as the reader edits them** (Settings ▸ General; manifest section 6's first row): a typed
/// name or a pasted address is validated and kept as its host, in the one stored hover policy, and the gate's policy
/// refuses it at once — and, with any site excluded, refuses a page whose address cannot be read (fail-closed).
@MainActor
struct ExcludedSitesTests {
    /// **A pasted address is kept as its host, lowercased**, and reaches the gate's policy. Red while the row has no way in.
    @Test func aPastedAddressIsKeptAsItsHostAndRefusedAtOnce() throws {
        let control = try hover()
        #expect(control.addExcludedSite("  https://Docs.Example.com/page?q=1 ") == .added("docs.example.com"))
        #expect(control.excludedSites == ["docs.example.com"])
        #expect(control.effectivePolicy.refuses(.known("docs.example.com")))
        #expect(control.effectivePolicy.refuses(.known("a.docs.example.com")), "a subdomain of an excluded site")
        #expect(!control.effectivePolicy.refuses(.known("example.org")))
    }

    /// **What is not a site is refused, and nothing is stored**: an exclusion that can match no page is a promise that
    /// covers nothing.
    @Test func whatIsNotASiteIsRefusedAndNothingIsStored() throws {
        let control = try hover()
        for typed in ["", "   ", "not a host!", "exa mple.com", "..", "-bad.example", "example.com:abc"] {
            #expect(control.addExcludedSite(typed) == .notASite, "\(typed)")
        }
        #expect(control.excludedSites.isEmpty)
        #expect(control.policy.excludedHosts.isEmpty)
    }

    /// **The same site twice is said, not doubled**, however it was typed.
    @Test func theSameSiteTwiceIsSaid() throws {
        let control = try hover()
        #expect(control.addExcludedSite("example.com") == .added("example.com"))
        #expect(control.addExcludedSite("EXAMPLE.COM.") == .alreadyExcluded("example.com"))
        #expect(control.excludedSites == ["example.com"])
    }

    /// **Fail-closed**: with any site excluded, a page whose address cannot be read is refused; with none, nothing is.
    @Test func anUnreadablePageIsRefusedOnceAnySiteIsExcluded() throws {
        let control = try hover()
        #expect(!control.effectivePolicy.refuses(.unreadable))
        _ = control.addExcludedSite("example.com")
        #expect(control.effectivePolicy.refuses(.unreadable))
        #expect(!control.effectivePolicy.refuses(.notWebContent))
    }

    /// **Kept across launches in the hover policy's one stored value**, and removed by the reader's Remove.
    @Test func theListSurvivesALaunchAndRemoveTakesItOut() throws {
        let suite = try #require(UserDefaults(suiteName: "ai.xdict.tests.sites.\(UUID().uuidString)"))
        _ = try hover(suite).addExcludedSite("bücher.de")
        _ = try hover(suite).addExcludedSite("example.com")
        #expect(try hover(suite).excludedSites == ["example.com", "xn--bcher-kva.de"])
        #expect(HoverPolicyStore(defaults: suite).load().excludedHosts == ["example.com", "xn--bcher-kva.de"])
        try hover(suite).removeExcludedSite("example.com")
        #expect(try hover(suite).excludedSites == ["xn--bcher-kva.de"])
    }
}

/// **The hover rest time, from capture's own choices** (Settings ▸ General; manifest section 6's second row): the picker
/// offers `HoverPolicy.settleChoices` and nothing else, and the chosen rest reaches the gate.
@MainActor
struct SettleChoiceTests {
    @Test func theShippedRestIsShownAndTheChosenOneIsKept() throws {
        let suite = try #require(UserDefaults(suiteName: "ai.xdict.tests.settle.\(UUID().uuidString)"))
        let control = try hover(suite)
        #expect(control.settle == .standard)
        control.setSettle(.patient)
        #expect(control.effectivePolicy.settleMilliseconds == HoverPolicy.Settle.patient.milliseconds)
        #expect(try hover(suite).settle == .patient)
    }

    /// **A stored rest that is no choice is shown as the nearest choice**, and left as stored until the reader picks one.
    @Test func aStoredRestThatIsNoChoiceShowsTheNearest() throws {
        let suite = try #require(UserDefaults(suiteName: "ai.xdict.tests.settle.\(UUID().uuidString)"))
        var odd = HoverPolicy.shipped
        odd.settleMilliseconds = HoverPolicy.Settle.relaxed.milliseconds - 1
        HoverPolicyStore(defaults: suite).save(odd)
        let control = try hover(suite)
        #expect(control.settle == .relaxed)
        #expect(control.policy.settleMilliseconds == odd.settleMilliseconds)
    }
}

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

    /// **A stored rest that is not exactly one of the choices is the shipped rest**, on load and in the picker alike, so
    /// the picker and the gate agree — never the nearest choice, and never a trap: `Int.min` once trapped in the
    /// nearest-choice arithmetic (verifier, 2026-10-19). A valid choice is kept.
    @Test(arguments: [Int.min, Int.max, -180, -1, 0, 179, 1_000_000])
    func aStoredRestThatIsNoChoiceIsTheShippedRest(stored: Int) throws {
        let suite = try #require(UserDefaults(suiteName: "ai.xdict.tests.settle.\(UUID().uuidString)"))
        var odd = HoverPolicy.shipped
        odd.settleMilliseconds = stored
        HoverPolicyStore(defaults: suite).save(odd)
        let control = try hover(suite)
        #expect(control.settle == .standard)
        #expect(control.policy.settleMilliseconds == HoverPolicy.shipped.settleMilliseconds)
        #expect(control.effectivePolicy.settleMilliseconds == HoverPolicy.shipped.settleMilliseconds)
    }

    @Test func aStoredValidChoiceIsKept() throws {
        let suite = try #require(UserDefaults(suiteName: "ai.xdict.tests.settle.\(UUID().uuidString)"))
        var chosen = HoverPolicy.shipped
        chosen.settleMilliseconds = HoverPolicy.Settle.relaxed.milliseconds
        HoverPolicyStore(defaults: suite).save(chosen)
        #expect(try hover(suite).settle == .relaxed)
        #expect(try hover(suite).policy.settleMilliseconds == HoverPolicy.Settle.relaxed.milliseconds)
    }
}

/// **What a typed site may be** (verifier, 2026-10-19): a host name within DNS's limits — 253 characters, 63 a label —
/// and never a single label such as `com`, which would cover every site under it; and a list of bounded length.
@MainActor
struct ExcludedSiteLimitTests {
    @Test func aNameOverTheDNSLimitsIsNotASite() throws {
        let control = try hover()
        let label63 = String(repeating: "a", count: 63)
        #expect(control.addExcludedSite("\(label63).example.com") == .added("\(label63).example.com"))
        #expect(control.addExcludedSite(String(repeating: "a", count: 64) + ".example.com") == .notASite)
        // 4 labels of 63 and the dots: 255 characters, over the 253 a name may have.
        let long = Array(repeating: label63, count: 4).joined(separator: ".")
        #expect(control.addExcludedSite(long) == .notASite)
        #expect(control.excludedSites == ["\(label63).example.com"])
    }

    /// **A single label covers too much**: `com` would exclude every `.com` site; said, and nothing stored. An address
    /// family literal is not a label and stays allowed.
    @Test func aSingleLabelIsTooBroad() throws {
        let control = try hover()
        for typed in ["com", "COM.", "https://com/", "localhost"] {
            #expect(control.addExcludedSite(typed) == .tooBroad, "\(typed)")
        }
        #expect(control.excludedSites.isEmpty)
        #expect(control.addExcludedSite("[::1]") == .added("::1"))
    }

    /// **The list is bounded**: past `HoverControl.excludedSiteLimit` a site is refused with its sentence.
    @Test func theListIsBounded() throws {
        let control = try hover()
        for index in 0..<HoverControl.excludedSiteLimit {
            #expect(control.addExcludedSite("site\(index).example.com") == .added("site\(index).example.com"))
        }
        #expect(control.addExcludedSite("one-more.example.com") == .listFull)
        #expect(control.excludedSites.count == HoverControl.excludedSiteLimit)
    }
}

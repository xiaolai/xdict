import Foundation
import Testing
import XDictCapture

/// **The excluded hosts are parsed once, when the list is set or decoded, never per decision** (verifier, 2026-10-19):
/// `refuses` runs on every hover and every selection read, and it parsed each stored entry each time.
struct HoverHostCacheTests {
    private func policy(hosts count: Int) -> HoverPolicy {
        var policy = HoverPolicy.shipped
        policy.excludedHosts = Set((0..<count).map { "site\($0).example.com" })
        return policy
    }

    /// **20,000 entries decide in under 5 ms** a call, a hit and a miss alike. Red while every call parses every entry.
    @Test func aLongListDecidesQuickly() {
        let policy = policy(hosts: 20_000)
        let clock = ContinuousClock()
        let calls = 20
        let spent = clock.measure {
            for index in 0..<calls {
                _ = policy.refuses(.known("www.site\(index).example.com"))
                _ = policy.refuses(.known("not-listed\(index).example.org"))
            }
        }
        #expect(spent / (2 * calls) < .milliseconds(5), "\(spent / (2 * calls)) a call")
        #expect(policy.refuses(.known("a.site19999.example.com")))
        #expect(!policy.refuses(.known("site20000.example.com")))
    }

    /// **The cache follows the list**: set, changed and decoded, the decision is the list's now — never a stale one.
    @Test func theCacheFollowsTheList() throws {
        var policy = HoverPolicy.shipped
        #expect(!policy.refuses(.known("example.com")))
        policy.excludedHosts = ["EXAMPLE.com."]
        #expect(policy.refuses(.known("www.example.com")))
        policy.excludedHosts.remove("EXAMPLE.com.")
        #expect(!policy.refuses(.known("www.example.com")))
        policy.excludedHosts.insert("https://docs.example.org/page")
        let decoded = try JSONDecoder().decode(HoverPolicy.self, from: JSONEncoder().encode(policy))
        #expect(decoded.refuses(.known("docs.example.org")))
        #expect(decoded == policy)
        let encoded = try #require(String(data: JSONEncoder().encode(policy), encoding: .utf8))
        #expect(!encoded.contains("parsed"), "the cache was stored: \(encoded)")
    }
}

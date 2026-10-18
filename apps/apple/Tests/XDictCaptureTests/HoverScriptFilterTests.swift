import Foundation
import Testing
import XDictCapture

/// **Capture's own script filter, handed in** (ADR-0014 decision 10): not XiaolaiDict's study setting — no default, no
/// stored key of that name, and nil or empty filters nothing.
struct HoverScriptFilterTests {
    private func policy(_ allowed: Set<CaptureScript>?) -> HoverPolicy {
        HoverPolicy(modifier: .option, excludedApps: [], excludedHosts: [], settleMilliseconds: 0, allowedScripts: allowed)
    }

    @Test func nothingIsFilteredUnlessTheConsumerSaysSo() {
        #expect(HoverPolicy.shipped.allowedScripts == nil, "capture ships no script choice of its own")
        for word in ["hold", "水", "한글", "する"] {
            #expect(HoverPolicy.shipped.allows(word), "\(word) was filtered by default")
            #expect(policy([]).allows(word), "an empty set filtered \(word)")
        }
    }

    @Test func aWordInAScriptNotAllowedIsRefused() {
        let latin = policy([.latin])
        #expect(latin.allows("hold"))
        #expect(!latin.allows("水"))
        #expect(latin.allows("42"), "text in no script is allowed")
        #expect(policy([.han]).allows("水"))
    }

    @Test func theRefusalSaysNotAllowed() {
        #expect(HoverRefusal(rawValue: "scriptNotAllowed") == .scriptNotAllowed)
        #expect(!HoverRefusal.allCases.map(\.rawValue).contains { $0.lowercased().contains("stud") })
    }

    /// The stored shape has no `scripts` key, and a value written without the field decodes to no filter.
    @Test func theStoredPolicyHasNoStudySetting() throws {
        let data = try JSONEncoder().encode(policy([.latin]))
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(!keys.contains("scripts"))
        #expect(keys.contains("allowedScripts"))
        let bare = Data(#"{"modifier":"option","excludedApps":[],"excludedHosts":[],"settleMilliseconds":0}"#.utf8)
        #expect(try JSONDecoder().decode(HoverPolicy.self, from: bare).allowedScripts == nil)
    }
}

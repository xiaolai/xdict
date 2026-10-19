import Foundation
import Testing
import XDictAnywhere
import XDictCapture

/// **The hover policy, kept across launches** (XiaolaiDict's `HoverPolicyStoreTests`, moved by name in plan-capture WI-3;
/// the store lives in the composition layer, which owns the reader's settings).
struct HoverPolicyStoreTests {
    private func store() throws -> (HoverPolicyStore, UserDefaults) {
        // A suite of its own, so a test can never read or write the reader's real preferences.
        let defaults = try #require(UserDefaults(suiteName: "ai.xdict.tests.hover.\(UUID().uuidString)"))
        return (HoverPolicyStore(defaults: defaults), defaults)
    }

    @Test func withNothingSavedItIsTheShippedPolicy() throws {
        let (store, _) = try store()
        #expect(store.load() == .shipped)
    }

    @Test func whatTheReaderChoseSurvivesALaunch() throws {
        let (store, defaults) = try store()
        var chosen = HoverPolicy.shipped
        chosen.modifier = .control
        chosen.gesture = .doubleTap
        chosen.settleMilliseconds = 300
        store.save(chosen)
        let reopened = HoverPolicyStore(defaults: defaults).load()
        #expect(reopened.modifier == .control)
        #expect(reopened.gesture == .doubleTap)
        #expect(reopened.settleMilliseconds == 300)
    }

    /// **Read text with: Automatic unless the reader chose Screen Only**, which survives a launch.
    @Test func theReadingModeIsAutomaticUntilChosenAndSurvivesALaunch() throws {
        let (store, defaults) = try store()
        #expect(store.load().readingMode == .automatic)
        var chosen = HoverPolicy.shipped
        chosen.readingMode = .screenOnly
        store.save(chosen)
        #expect(HoverPolicyStore(defaults: defaults).load().readingMode == .screenOnly)
    }

    /// **A stored reading mode no version wrote is Automatic, and the rest of the policy stands**: a mode a later version
    /// adds, read by this one, must not reset the reader's exclusions (the whole blob would otherwise fail to decode).
    /// And a policy stored before the mode existed reads as Automatic, its exclusions kept.
    @Test func anUnknownOrMissingReadingModeIsAutomaticAndKeepsThePolicy() throws {
        let (store, defaults) = try store()
        var chosen = HoverPolicy.shipped
        chosen.excludedApps.insert("com.example.kept")
        chosen.readingMode = .screenOnly
        store.save(chosen)
        let saved = try #require(defaults.data(forKey: HoverPolicyStore.defaultsKey))
        var object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        for stored: Any? in ["pixelsAndSound", 7, nil] {
            object["readingMode"] = stored
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: HoverPolicyStore.defaultsKey)
            let loaded = HoverPolicyStore(defaults: defaults).load()
            #expect(loaded.readingMode == .automatic, "stored \(String(describing: stored))")
            #expect(loaded.excludedApps.contains("com.example.kept"), "an odd reading mode reset the exclusions")
        }
    }

    /// **Unreadable is the default, never a failure and never an empty policy.**
    @Test func anUnreadableValueFallsBackToShipped() throws {
        let (store, defaults) = try store()
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: HoverPolicyStore.defaultsKey)
        #expect(store.load() == .shipped)
    }

    @Test func aValueOfTheWrongTypeAltogetherFallsBackToShipped() throws {
        let (store, defaults) = try store()
        defaults.set("not a policy", forKey: HoverPolicyStore.defaultsKey)
        #expect(store.load() == .shipped)
    }

    /// **The password-manager exclusion is a rule, not a preference, so loading restores it**: capture always takes the
    /// sentence around a word, and in a password manager the whole surface is secrets.
    @Test func aStoredPolicyCannotDropThePasswordManagers() throws {
        let (store, defaults) = try store()
        var permissive = HoverPolicy.shipped
        permissive.excludedApps = []
        store.save(permissive)
        #expect(HoverPolicyStore(defaults: defaults).load().excludedApps.isSuperset(of: HoverPolicy.defaultExcludedApps),
                "a saved policy dropped the password managers and the store believed it")
    }

    /// What the reader adds is kept alongside the rule, not replaced by it.
    @Test func theReadersOwnExclusionsAreKept() throws {
        let (store, defaults) = try store()
        var chosen = HoverPolicy.shipped
        chosen.excludedApps.insert("com.example.Diary")
        store.save(chosen)
        let reopened = HoverPolicyStore(defaults: defaults).load()
        #expect(reopened.excludedApps.contains("com.example.Diary"))
        #expect(reopened.excludedApps.isSuperset(of: HoverPolicy.defaultExcludedApps))
    }

    /// **A policy stored before a field existed must still load** (renamed from
    /// `aPolicyStoredBeforeScriptsExistedKeepsItsExclusions`: in XDict the field added later is the gesture). A decoder
    /// requiring a key the old value lacks would throw, and `load` would silently discard every exclusion.
    @Test func aPolicyStoredBeforeTheGestureExistedKeepsItsExclusions() throws {
        let (_, defaults) = try store()
        let old = """
            {"modifier":"option","excludedApps":["com.example.vault"],"excludedHosts":[],"settleMilliseconds":300}
            """
        defaults.set(Data(old.utf8), forKey: HoverPolicyStore.defaultsKey)
        let loaded = HoverPolicyStore(defaults: defaults).load()
        #expect(loaded.excludedApps.contains("com.example.vault"), "the reader's exclusions were lost")
        #expect(loaded.settleMilliseconds == 300)
        #expect(loaded.gesture == .hold)
    }

    /// **The scripts are never stored** (renamed from `anEmptyScriptSetIsCorrectedOnTheWayIn`): they are derived from the
    /// enabled dictionaries' languages each time (ADR-0014 d.10), so a value saved with scripts, or a blob carrying them,
    /// loads with none — the consumer's derivation decides.
    @Test func storedScriptsAreNeverTrusted() throws {
        let (store, defaults) = try store()
        var policy = HoverPolicy.shipped
        policy.allowedScripts = []
        store.save(policy)
        #expect(HoverPolicyStore(defaults: defaults).load().allowedScripts == nil, "a saved script set was kept")
        let planted = """
            {"modifier":"option","excludedApps":[],"excludedHosts":[],"settleMilliseconds":180,"allowedScripts":["han"]}
            """
        defaults.set(Data(planted.utf8), forKey: HoverPolicyStore.defaultsKey)
        #expect(HoverPolicyStore(defaults: defaults).load().allowedScripts == nil, "a stored script set was trusted")
    }
}

import Foundation
import Testing
import XDictTestSupport
import XDictUI

/// **The system facts read from undocumented preferences** (plan-setup-v2 WI-5): the Service's `pbs` entry, Apple's Look
/// Up symbolic hotkey, the trackpad's three-finger tap and Apple's active dictionaries — each read into a value tree and
/// judged by a pure function, so the tests state the formats and never touch this Mac's own settings.
///
/// **The rule every test here shares**: a key that is missing, a value of another type, or a domain nobody read is
/// `.unreadable`. Never `.ready`: a row that says "check" costs the reader a look; a green row over a guess costs the
/// trust in every other row.
struct SystemProbesTests {
    // MARK: - The Service

    /// The row promises one thing — Look Up in XDict in every app's Services menu — so it reads that one switch.
    @Test func theServiceIsOnWhenPbsSaysItsServicesMenuEntryIsOn() {
        let pbs = PlistValue.dictionary(["NSServicesStatus": .dictionary([
            "ai.xdict.app/lookUpInXDict": .dictionary(["enabled_context_menu": .bool(false),
                                                       "enabled_services_menu": .bool(true),
                                                       "presentation_modes": .dictionary(["ContextMenu": .bool(true)])]),
            "com.other.app/something": .dictionary(["enabled_services_menu": .bool(true)]),
        ])])
        #expect(SystemProbes.services(in: pbs) == .ready)
    }

    /// `defaults` writes a boolean as `0`/`1` in several of these domains, so both spellings are the same fact.
    @Test func theServiceOffIsWaitingAndAnIntegerIsASwitch() {
        for value in [PlistValue.bool(false), .integer(0)] {
            let pbs = PlistValue.dictionary(["NSServicesStatus": .dictionary([
                "ai.xdict.app/lookUpInXDict": .dictionary(["enabled_services_menu": value])])])
            #expect(SystemProbes.services(in: pbs) == .waiting(count: nil), "\(value)")
        }
        for value in [PlistValue.bool(true), .integer(1)] {
            let pbs = PlistValue.dictionary(["NSServicesStatus": .dictionary([
                "ai.xdict.app/lookUpInXDict": .dictionary(["enabled_services_menu": value])])])
            #expect(SystemProbes.services(in: pbs) == .ready, "\(value)")
        }
    }

    /// **A service macOS has never recorded is not a service that is off**: absence is `.unreadable`, never `.waiting`
    /// and never `.ready`.
    @Test func anUnreadableServiceSaysCheck() {
        #expect(SystemProbes.services(in: nil) == .unreadable)
        #expect(SystemProbes.services(in: .dictionary([:])) == .unreadable)
        #expect(SystemProbes.services(in: .dictionary(["NSServicesStatus": .array([])])) == .unreadable)
        #expect(SystemProbes.services(in: .dictionary(["NSServicesStatus": .dictionary([:])])) == .unreadable)
        #expect(SystemProbes.services(in: .dictionary(["NSServicesStatus": .dictionary([
            "ai.xdict.app/lookUpInXDict": .dictionary([:])])])) == .unreadable, "no key at all")
        #expect(SystemProbes.services(in: .dictionary(["NSServicesStatus": .dictionary([
            "ai.xdict.app/lookUpInXDict": .dictionary(["enabled_services_menu": .string("yes")])])])) == .unreadable,
            "a string is not a switch")
        #expect(SystemProbes.services(in: .dictionary(["NSServicesStatus": .dictionary([
            "ai.xdict.app/lookUpInXDict": .dictionary(["enabled_services_menu": .integer(2)])])])) == .unreadable,
            "2 is not a switch either")
    }

    // MARK: - Apple's Look Up shortcut

    @Test func applesLookUpHotkeyIsGreenOnlyWhenReadAsOff() {
        let domain = PlistValue.dictionary(["AppleSymbolicHotKeys": .dictionary([
            "70": .dictionary(["enabled": .integer(0)]),
            "79": .dictionary(["enabled": .integer(1)]),
        ])])
        #expect(SystemProbes.symbolicLookUp(in: domain) == .ready)
        let on = PlistValue.dictionary(["AppleSymbolicHotKeys": .dictionary([
            "70": .dictionary(["enabled": .bool(true)])])])
        #expect(SystemProbes.symbolicLookUp(in: on) == .waiting(count: nil))
    }

    /// **macOS keeps only the shortcuts the reader has touched**, so key 70 is often absent — measured on this Mac,
    /// 2026-10-22, where the domain holds 15…82 and no 70. Absence is the row saying "check", not "off".
    @Test func anAbsentSymbolicHotkeyIsUnreadable() {
        let touched = PlistValue.dictionary(["AppleSymbolicHotKeys": .dictionary([
            "15": .dictionary(["enabled": .integer(0)])])])
        #expect(SystemProbes.symbolicLookUp(in: touched) == .unreadable)
        #expect(SystemProbes.symbolicLookUp(in: nil) == .unreadable)
        let mistyped = PlistValue.dictionary(["AppleSymbolicHotKeys": .dictionary(["70": .string("on")])])
        #expect(SystemProbes.symbolicLookUp(in: mistyped) == .unreadable)
    }

    // MARK: - The three-finger tap

    @Test func theThreeFingerTapIsGreenWhenEveryTrackpadSaysZero() {
        let zero = PlistValue.dictionary(["TrackpadThreeFingerTapGesture": .integer(0)])
        #expect(SystemProbes.threeFingerTap(domains: [zero, zero]) == .ready)
        #expect(SystemProbes.threeFingerTap(domains: [nil, zero]) == .ready, "a Mac with no Bluetooth trackpad")
        let on = PlistValue.dictionary(["TrackpadThreeFingerTapGesture": .integer(2)])
        #expect(SystemProbes.threeFingerTap(domains: [zero, on]) == .waiting(count: nil))
        #expect(SystemProbes.threeFingerTap(domains: [on, nil]) == .waiting(count: nil))
    }

    /// A domain that is there but says nothing about the gesture is not an answer: the other trackpad might have it on.
    @Test func aTrackpadDomainWithoutTheKeyIsUnreadable() {
        let silent = PlistValue.dictionary(["TrackpadScroll": .integer(1)])
        let zero = PlistValue.dictionary(["TrackpadThreeFingerTapGesture": .integer(0)])
        #expect(SystemProbes.threeFingerTap(domains: [silent, zero]) == .unreadable)
        #expect(SystemProbes.threeFingerTap(domains: [silent, silent]) == .unreadable)
        #expect(SystemProbes.threeFingerTap(domains: [nil, nil]) == .unreadable)
        #expect(SystemProbes.threeFingerTap(domains: []) == .unreadable)
    }

    // MARK: - Apple's active dictionaries

    /// **The three forms the array holds**, as read on this Mac 2026-10-22: a container path, a Resources path and a bare
    /// identifier. Only the last two are Apple's by the plan's rule: the AssetsV2 install path, or `com.apple.dictionary.`.
    @Test func applesActiveDictionariesAreCountedByPathOrIdentifier() {
        let domain = PlistValue.dictionary(["DCSActiveDictionaries": .array([
            .string("/Users/x/Library/Containers/com.apple.Dictionary/Data/Library/Dictionaries/Oxford "
                    + "Collocation Dictionary.dictionary"),
            .string("/System/Library/AssetsV2/com_apple_MobileAsset_DictionaryServices_dictionary3macOS/a.asset/"
                    + "AssetData/Apple Dictionary.dictionary"),
            .string("/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/"
                    + "Resources/Wikipedia.wikipediadictionary"),
            .string("com.apple.dictionary.NOAD"),
            .string("com.apple.dictionary.yue-en.oup"),
        ])])
        #expect(SystemProbes.activeAppleDictionaries(in: domain) == .waiting(count: 3))
    }

    @Test func noActiveAppleDictionaryIsGreen() {
        #expect(SystemProbes.activeAppleDictionaries(in: .dictionary(["DCSActiveDictionaries": .array([])])) == .ready)
        let readers = PlistValue.dictionary(["DCSActiveDictionaries": .array([
            .string("/Users/x/Library/Dictionaries/Mine.dictionary")])])
        #expect(SystemProbes.activeAppleDictionaries(in: readers) == .ready)
    }

    @Test func anUnreadableDictionaryListSaysCheck() {
        #expect(SystemProbes.activeAppleDictionaries(in: nil) == .unreadable)
        #expect(SystemProbes.activeAppleDictionaries(in: .dictionary([:])) == .unreadable)
        #expect(SystemProbes.activeAppleDictionaries(in: .dictionary(["DCSActiveDictionaries": .string("com.apple.NOAD")]))
            == .unreadable, "one string is not a list")
        #expect(SystemProbes.activeAppleDictionaries(in: .dictionary(["DCSActiveDictionaries": .array([.integer(3)])]))
            == .unreadable, "an entry that is not a name")
    }

    // MARK: - The four together

    /// **One read, four domains**, each asked of the injected reader: what the pane's Recheck does, without the system.
    /// Each answer can only come from its own domain — `.ready` for the Service from `pbs`, the shortcut's `.waiting`
    /// from the symbolic hotkeys, the trackpad's `.ready` from both trackpad domains, the count from `DCSActiveDictionaries`
    /// — so the reading below is also the proof that every domain was asked. (This target may not import `os`, so the
    /// reader is not instrumented; `ModuleBoundaryTests` holds that list.)
    @Test func oneReadAsksEachDomainAndJudgesIt() {
        let fixtures: [String: PlistValue] = [
            "pbs": .dictionary(["NSServicesStatus": .dictionary([
                "ai.xdict.app/lookUpInXDict": .dictionary(["enabled_services_menu": .integer(1)])])]),
            "com.apple.symbolichotkeys": .dictionary(["AppleSymbolicHotKeys": .dictionary([
                "70": .dictionary(["enabled": .integer(1)])])]),
            "com.apple.AppleMultitouchTrackpad": .dictionary(["TrackpadThreeFingerTapGesture": .integer(0)]),
            "com.apple.driver.AppleBluetoothMultitouch.trackpad": .dictionary(["TrackpadThreeFingerTapGesture": .integer(0)]),
            "com.apple.DictionaryServices": .dictionary(["DCSActiveDictionaries": .array([.string("com.apple.dictionary.NOAD")])]),
        ]
        let probes = SystemProbes { name in fixtures[name] }
        let reading = probes.read()
        #expect(reading.services == .ready)
        #expect(reading.appleLookUp == AppleLookUp(shortcut: .waiting(count: nil), trackpad: .ready,
                                                   dictionaries: .waiting(count: 1)))
        // A domain the reader leaves out is unreadable, not ready: one missing fixture is one "check".
        let partial = SystemProbes { name in name == "pbs" ? fixtures["pbs"] : nil }.read()
        #expect(partial.services == .ready)
        #expect(partial.appleLookUp.isUnreadable)
    }

    /// Nothing read at all: the board says "check" three ways, and the row is never green.
    @Test func aSystemThatAnswersNothingIsNeverGreen() {
        let reading = SystemProbes { _ in nil }.read()
        #expect(reading.services == .unreadable)
        #expect(reading.appleLookUp.isUnreadable)
        #expect(!reading.appleLookUp.isClear)
    }

    // MARK: - Read-only, and it stays that way

    /// **The probe files write nothing**: every preference API they name is a read. A `SetAppValue` here would be XDict
    /// changing the system for the reader, which plan-setup-v2's principles forbid outright.
    @Test func theProbesOnlyReadPreferences() throws {
        let files = ["Sources/XDictUI/SystemProbes.swift", "Sources/XDictAppleSource/AvailableBundles.swift"]
        let writers = ["CFPreferencesSet", "CFPreferencesSetAppValue", "CFPreferencesSetMultiple",
                       "CFPreferencesAppSynchronize", "SetAppValue", "SCPreferencesSet"]
        var found: [String] = []
        for path in files {
            let text = try String(contentsOf: Manifest.package.appending(path: path), encoding: .utf8)
            let code = SourceScan.codeOnly(text)
            found += writers.filter { code.contains($0) }.map { "\(path): \($0)" }
        }
        #expect(found.isEmpty, "a probe writes a system preference: \(found)")
        // The control: the same detector, on a planted write, finds it.
        let planted = SourceScan.codeOnly("CFPreferencesSetAppValue(key, value, domain)")
        #expect(writers.contains { planted.contains($0) })
    }
}

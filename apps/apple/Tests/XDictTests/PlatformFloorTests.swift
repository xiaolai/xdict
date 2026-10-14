import Foundation
import Testing
import XDictTestSupport

/// **One platform floor, held in every place that states it.** AGENTS.md decides macOS 27. The floor is written four
/// times — the manifest, the app's and the service's `LSMinimumSystemVersion`, and `Tools/build-bundle.sh`, which holds
/// every binary's `minos` to it — and nothing but this test holds them together. Raising any one alone, by one, fails
/// here; raising the floor is an edit of all four and of this constant, in one change.
struct PlatformFloorTests {
    static let floor = "27.0"

    @Test func theManifestDeclaresTheFloor() throws {
        let stated = try Self.manifestFloor()
        #expect(Self.problems(stated: ["Package.swift": stated]) == [])
    }

    @Test func bothInfoPlistsDeclareTheFloor() throws {
        var stated: [String: String?] = [:]
        for plist in ["Resources/Info.plist", "Resources/DictionaryService-Info.plist"] {
            let values = try Self.plist(plist)
            // `updateValue`, not a subscript: assigning nil through a subscript removes the key, and a plist with no
            // floor would then be one nothing checks.
            stated.updateValue(values["LSMinimumSystemVersion"] as? String, forKey: plist)
        }
        #expect(Self.problems(stated: stated) == [])
    }

    @Test func theBundleScriptHoldsBinariesToTheFloor() throws {
        let script = try String(contentsOf: Manifest.package.appending(path: "Tools/build-bundle.sh"), encoding: .utf8)
        let declared = script.split(separator: "\n").first { $0.hasPrefix("readonly MINIMUM_MACOS=") }
            .map { String($0.dropFirst("readonly MINIMUM_MACOS=".count)) }
        #expect(Self.problems(stated: ["Tools/build-bundle.sh": declared]) == [])
    }

    /// The control: a floor raised by one, a floor dropped, and one written as a different spelling are each refused.
    @Test func aFloorRaisedByOneIsRefused() {
        #expect(Self.problems(stated: ["a": "28.0"]) == ["a states 28.0, not 27.0"])
        #expect(Self.problems(stated: ["a": nil]) == ["a states no floor"])
        #expect(Self.problems(stated: ["a": "27"]) == ["a states 27, not 27.0"])
        #expect(Self.problems(stated: ["a": "27.0"]) == [])
        var dropped: [String: String?] = [:]
        dropped.updateValue(nil, forKey: "b")
        #expect(Self.problems(stated: dropped) == ["b states no floor"])
    }

    /// The control for the manifest's reading: a copy of the manifest with the floor raised by one, as SwiftPM evaluates
    /// it. (Raised in the real manifest, today's SDK refuses the build first — "the range of supported deployment target
    /// versions is 12.0 to 27.0.x" — which would stop being true the day a newer SDK ships; this test would not.)
    @Test func aManifestFloorRaisedByOneIsNamed() throws {
        let manifest = try String(contentsOf: Manifest.package.appending(path: "Package.swift"), encoding: .utf8)
        let declared = #"platforms: [.macOS("27.0")]"#
        #expect(manifest.components(separatedBy: declared).count == 2, "premise: the manifest declares the floor once")
        let raised = try TemporaryDirectory(named: "xdict-raised-floor")
        try manifest.replacingOccurrences(of: declared, with: #"platforms: [.macOS("28.0")]"#)
            .write(to: raised.appending("Package.swift"), atomically: true, encoding: .utf8)
        let stated = try Self.manifestFloor(of: raised.url)
        #expect(Self.problems(stated: ["Package.swift": stated]) == ["Package.swift states 28.0, not 27.0"])
    }

    static func problems(stated: [String: String?]) -> [String] {
        stated.sorted { $0.key < $1.key }.compactMap { place, value in
            guard let value else { return "\(place) states no floor" }
            return value == floor ? nil : "\(place) states \(value), not \(floor)"
        }
    }

    /// The manifest's macOS floor as SwiftPM reads it, or nil where it declares none.
    static func manifestFloor(of root: URL = Manifest.package) throws -> String? {
        try Manifest.dump(of: root).platforms.first { $0.hasPrefix("macos ") }.map { String($0.dropFirst("macos ".count)) }
    }

    static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Manifest.package.appending(path: path))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}

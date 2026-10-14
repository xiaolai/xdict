import Foundation
import Testing
import XDictTestSupport

/// **A target that stops running its tests looks exactly like a target whose tests pass** (adapted from XiaolaiDict's
/// `TestInventoryTests`). There, a scripted edit emptied five files; everything compiled, `swift test` exited 0 with
/// every line "passed", and one target had gone from 47 tests to 4. The number was the only thing that said so.
///
/// So each test target has a floor: the fewest `@Test` declarations it may hold. Floors, not equalities: adding a test
/// needs no edit here, and only a drop is a signal. Lowering one is a deliberate line in a diff, with its reason.
struct TestInventoryTests {
    /// Set to each target's count when the skeleton landed (2026-10-14, WI-2); `XDictContractTests` added, and the
    /// service's and the harness's raised, with the frozen contract and its Codex refutation (2026-10-14, WI-1);
    /// `XDictEntryViewTests` added with the entry view, and the harness's raised by its boundary rows (2026-10-14, WI-4).
    static let floors = [
        // 8 → 2 (WI-3): the handshake became the contract's `versions`; its tests moved with it, to XDictClientTests
        // (`LaunchHandshakeTests`) and XDictServiceTests (`ServiceContractTests`).
        "XDictBaseTests": 2,
        "XDictClientTests": 15,
        "XDictContractTests": 67,
        "XDictUITests": 3,
        "XDictEntryViewTests": 36,
        "XDictServiceTests": 37,
        "XDictTests": 35,
    ]

    @Test func everyTargetStillRunsTheTestsItHad() throws {
        let shortfalls = try Self.floors.sorted(by: { $0.key < $1.key }).compactMap { target, floor -> String? in
            let found = try Self.tests(in: target)
            return found < floor ? "\(target): \(found) @Test, floor \(floor)" : nil
        }
        #expect(shortfalls.isEmpty, """
            a test target lost tests — \(shortfalls.joined(separator: "; ")). If they were deliberately deleted, lower \
            the floor in the same change and say why.
            """)
    }

    /// **The floors name every test target SwiftPM knows**, read off the manifest: a target with no floor is one the
    /// guard does not cover, and it goes on passing whatever happens to it.
    @Test func everyTestTargetHasAFloor() throws {
        let declared = try Manifest.dump().targets.values.filter { $0.type == "test" }.map(\.name)
        #expect(Set(declared) == Set(Self.floors.keys), """
            test targets in Package.swift: \(declared.sorted()); with a floor: \(Self.floors.keys.sorted())
            """)
    }

    /// A floor of zero guards nothing, and a directory that reads as empty passes every floor of zero.
    @Test func noFloorIsVacuous() throws {
        for (target, floor) in Self.floors {
            #expect(floor > 0, "\(target) has a floor of \(floor), which nothing can fail")
            #expect(try Self.tests(in: target) > 0, "no @Test found in \(target) at all")
        }
    }

    /// `@Test` attributes under `Tests/<target>`, comments and strings blanked: a comment explaining `@Test` is not one.
    static func tests(in target: String) throws -> Int {
        try SourceScan.files(under: Manifest.package.appending(path: "Tests/\(target)")).reduce(0) { count, file in
            count + SourceScan.codeOnly(file.text).components(separatedBy: "@Test").count - 1
        }
    }
}

import Foundation
import Testing
import XDictTestSupport
@testable import XDict

/// **Which main window takes a handed place** (audit round 4, 2026-10-26): the frontmost open window — key, then main,
/// then visible, then the last. The expansion with no window open is not decided here: `MainWindows.made` hands the place
/// to the window SwiftUI is making, which is the only state it knows was just created (audit 2026-10-29 finding 2).
@MainActor
struct MainWindowAdoptionTests {
    @Test func theFrontmostOpenWindowTakesThePlace() {
        #expect(MainWindows.adopter(open: [(key: false, main: false, visible: true),
                                           (key: true, main: false, visible: true),
                                           (key: false, main: true, visible: true)]) == 1,
                "the key window did not take the place")
        #expect(MainWindows.adopter(open: [(key: false, main: false, visible: true),
                                           (key: false, main: true, visible: true)]) == 1,
                "the main window did not take the place")
        #expect(MainWindows.adopter(open: [(key: false, main: false, visible: true),
                                           (key: false, main: false, visible: false)]) == 0,
                "a visible window lost the place to a hidden one")
        #expect(MainWindows.adopter(open: [(key: false, main: false, visible: false),
                                           (key: false, main: false, visible: false)]) == 1,
                "with none of them frontmost the newest did not take it")
        #expect(MainWindows.adopter(open: []) == nil, "with no window open one was chosen from nothing")
    }

    /// **`made` hands the place to the window it is making, and to no other** (audit 2026-10-29 finding 2): the fixed
    /// choice is `made`'s own state, so a state whose window had closed can never consume the place.
    @Test func madeAdoptsIntoTheWindowItIsMakingAndRunsNoChooser() throws {
        let source = try String(contentsOf: Manifest.package.appending(path: "Sources/XDict/LookupAnywhere.swift"),
                                encoding: .utf8)
        let body = try #require(DocumentDrawWiringTests.function("made", in: source), "made was not found")
        #expect(body.contains("adopt(place, into: state"),
                "made no longer hands the place to the state it is making")
        #expect(body.contains("if !deliver()"),
                "made adopts even when an open window should take the place first (round 4's rule)")
    }
}

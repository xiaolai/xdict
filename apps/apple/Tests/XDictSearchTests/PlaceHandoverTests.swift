import Foundation
import Testing
import XDictContract
import XDictSearch
import XDictTestSupport

/// **The panel expands into the main window keeping query, dictionary and scroll** (plan-macos-v1 WI-8, I5): the place
/// the panel's model is at — with how far down its entry the reader is — handed to another window's model, which shows
/// the same entry of the same dictionary at the same offset, in the same scope, as a new place in its own trail.
@MainActor
struct PlaceHandoverTests {
    @Test func theMainWindowTakesThePanelsPlaceWithItsScroll() async throws {
        let backend = FakeSearchBackend { query, dict, _ in
            let name = String(dict.rawValue.dropFirst("handle-".count))
            return .success(Fixture.page([Fixture.hit(name, query), Fixture.hit(name, query, 1)]))
        }
        let sources = Sources([Fixture.source(1, "A"), Fixture.source(2, "B")])
        let panel = SearchModelTests.model(backend, sources)
        panel.scrollReader = { 420 }
        panel.submit("abbé")
        await panel.idle()
        #expect(await eventually { panel.shown != nil })
        // The reader chose B's second record in the panel.
        panel.select(Fixture.result(2, "B", "abbé", 1))
        let place = try #require(await panel.currentPlace() as Visit?)
        #expect(place.query == "abbé")
        #expect(place.result == Fixture.result(2, "B", "abbé", 1))
        #expect(place.scroll == 420)

        let window = SearchModelTests.model(backend, sources)
        window.submit("earlier")
        await window.idle()
        window.adopt(place)
        await window.idle()
        #expect(window.text == "abbé")
        #expect(window.lookup?.query == "abbé")
        #expect(window.scope == place.scope)
        #expect(window.selection == Fixture.result(2, "B", "abbé", 1))
        #expect(window.shown?.result == Fixture.result(2, "B", "abbé", 1))
        #expect(window.shown?.landing == .offset(420))
        #expect(window.trail.visits.map(\.query) == ["earlier", "abbé"], "the place is the window's next, Back reaches its own")
    }

    /// **The adoption reports its own lookup, not an earlier queued navigation's** (verification finding, 2026-10-20): a
    /// Back suspended in `leaveCurrent` begins a lookup of the same word first; only the adoption's callback names the
    /// lookup whose presentations may bind a held sentence.
    @Test func anAdoptionReportsItsOwnLookupAfterASuspendedNavigation() async throws {
        let backend = FakeSearchBackend { query, dict, _ in
            let name = String(dict.rawValue.dropFirst("handle-".count))
            return .success(Fixture.page([Fixture.hit(name, query)]))
        }
        let sources = Sources([Fixture.source(1, "A")])
        let window = SearchModelTests.model(backend, sources)
        window.submit("earlier")
        await window.idle()
        window.submit("other")
        await window.idle()
        window.select(Fixture.result(1, "A", "other"))
        let place = Visit(query: "other", mode: .reader, scope: .all, result: Fixture.result(1, "A", "other"),
                          isOrigin: false)
        let gate = ScrollGate()
        window.scrollReader = { await gate.read() }
        window.back()
        var reported: [Int] = []
        window.adopt(place, started: { reported.append($0) })
        // Let the Back reach the scroll read; only then is it truly suspended, with the adoption queued behind it.
        for _ in 0..<1_000 where !gate.entered { await Task.yield() }
        #expect(gate.entered, "the Back must be held in the scroll read")
        #expect(reported.isEmpty, "the adoption has not begun while the navigation ahead of it is suspended")
        gate.release()
        await window.idle()
        #expect(reported == [try #require(window.lookup?.serial)], "the callback names the lookup the adoption began")
        #expect(window.lookup?.query == "other")
    }

    /// A panel with nothing shown has no place to hand over.
    @Test func noPlaceBeforeALookup() async {
        let panel = SearchModelTests.model(SearchModelTests.apples(), Sources([Fixture.source(1, "A")]))
        #expect(await panel.currentPlace() == nil)
    }
}

/// A scroll read that holds until released, then answers at once: the suspension point the adoption test needs.
@MainActor
final class ScrollGate {
    private(set) var entered = false
    private var waiting: CheckedContinuation<Double?, Never>?
    private var released = false

    func read() async -> Double? {
        entered = true
        if released { return 0 }
        return await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        released = true
        waiting?.resume(returning: 0)
        waiting = nil
    }
}

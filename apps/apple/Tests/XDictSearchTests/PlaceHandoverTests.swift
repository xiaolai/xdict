import Foundation
import Testing
import XDictContract
import XDictSearch

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

    /// A panel with nothing shown has no place to hand over.
    @Test func noPlaceBeforeALookup() async {
        let panel = SearchModelTests.model(SearchModelTests.apples(), Sources([Fixture.source(1, "A")]))
        #expect(await panel.currentPlace() == nil)
    }
}

import Foundation
import Testing
import XDictClient
import XDictContract
import XDictSearch
import XDictTestSupport

private enum ExamplesFixture {
    static let hit = ExampleHit(
        english: "Who could have considered such a possibility?", chinese: "谁居然会想到这种可能性？",
        start: 3, len: 6, sentence: true,
        sources: [ExampleSource(dict: Fixture.handle("one"),
                                entry: EntryRef(edition: Fixture.edition("one"), key: "consider", occurrence: 0),
                                headword: "consider")])

    static func answer(hits: [ExampleHit], notReady: [DictId] = [], total: UInt64? = nil,
                       capped: Bool = false) -> ClientOutcome {
        .success(Delivered(answer: .examples(Examples(hits: hits, total: total ?? UInt64(hits.count),
                                                      notReady: notReady, capped: capped)), payload: nil))
    }

    static func handles(_ names: [String] = ["one"]) -> [DictId] { names.map { Fixture.handle($0) } }
}

private func examplesOperations(_ backend: FakeSearchBackend) async
    -> [(query: String, dicts: [DictId], limit: UInt32)] {
    await backend.queued.compactMap {
        guard case .examples(let query, let dicts, let limit) = $0.operation else { return nil }
        return (query, dicts, limit)
    }
}

/// **The examples the main window asks for** (ADR-0031, plan-reverse-examples WI-5): a Chinese lookup asks the core
/// once, a non-Chinese one clears, and a store that finishes building at the service makes the model ask again — never
/// the query itself.
@MainActor
struct ExamplesModelTests {
    @Test func a_chinese_query_asks_every_dictionary_in_scope() async throws {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [ExamplesFixture.hit]) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(await eventually { model.hits.count == 1 })
        #expect(model.total == 1)
        #expect(model.hasContent)
        let hit = try #require(model.hits.first)
        #expect(hit.chinese == "谁居然会想到这种可能性？")
        let asked = await examplesOperations(backend)
        #expect(asked.count == 1)
        #expect(asked.first?.query == "居然")
        #expect(asked.first?.dicts == [Fixture.handle("one")])
        #expect(asked.first?.limit == ExamplesModel.page)

        // **Every dictionary in scope, in the reader's order** (audit round 4, 2026-10-25): two handles, then the same two
        // reversed, each asked exactly as given.
        let pair = ExamplesFixture.handles(["one", "two"])
        model.update(query: "居然", handles: pair)
        #expect(await eventually(awaiting: 2) { await examplesOperations(backend).count == 2 })
        #expect(await examplesOperations(backend).last?.dicts == pair)
        model.update(query: "居然", handles: Array(pair.reversed()))
        #expect(await eventually(awaiting: 2) { await examplesOperations(backend).count == 3 })
        #expect(await examplesOperations(backend).last?.dicts == Array(pair.reversed()))
    }

    /// **An older answer arriving after a newer one changes nothing** (audit round 4, 2026-10-25): the newer query's hits
    /// are the ones shown, whatever order the service answers in.
    @Test func an_older_answer_arriving_late_does_not_replace_the_newer() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        let older = ExamplesFixture.hit
        let newer = ExampleHit(english: "It will hold.", chinese: "它会持续。", start: 0, len: 2, sentence: true,
                               sources: older.sources)
        await backend.setAnswer { operation in
            if case .examples(let query, _, _) = operation, query == "居然" {
                return ExamplesFixture.answer(hits: [older])
            }
            return ExamplesFixture.answer(hits: [newer])
        }
        await backend.holdExamples()
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: ExamplesFixture.handles())
        // **Both requests reached the service before either was answered** (audit round 4, 2026-10-25): a release sent
        // before its request arrived was lost, and the request it belonged to then waited for the next release.
        #expect(await eventually(awaiting: 2) { await backend.heldExamples == ["居然"] })
        model.update(query: "会", handles: ExamplesFixture.handles())
        #expect(await eventually(awaiting: 2) { await backend.heldExamples == ["居然", "会"] })
        await backend.releaseExamples("会")
        #expect(await eventually { model.hits.first?.chinese == "它会持续。" })
        // The older request is still outstanding, and its answer arrives now — after the newer one has been shown.
        await backend.releaseExamples("居然")
        // **The late answer has been read** (audit round 4, 2026-10-25): the model counts every answer it receives before
        // deciding, so this wait is a barrier where a sleep was a guess.
        #expect(await eventually { model.answersRead == 2 }, "the late answer was never read")
        #expect(model.hits.first?.chinese == "它会持续。", "the older answer replaced the newer")
        #expect(model.query == "会")
    }

    @Test func a_latin_query_is_not_asked_and_clears_what_was() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [ExamplesFixture.hit]) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(await eventually { model.hits.count == 1 })
        model.update(query: "run", handles: ExamplesFixture.handles())
        #expect(model.hits.isEmpty)
        #expect(model.total == 0)
        #expect(!model.asked)
        let asked = await examplesOperations(backend)
        #expect(asked.count == 1)
    }

    @Test func a_store_that_finishes_building_asks_again() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        let handle = Fixture.handle("one")
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [], notReady: [handle]) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(await eventually { !model.notReady.isEmpty })
        #expect(model.hasContent, "a dictionary still preparing is something to say")
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [ExamplesFixture.hit]) }
        model.buildStateChanged(ready: [handle])
        #expect(await eventually { model.hits.count == 1 })
        #expect(model.notReady.isEmpty)
        let asked = await examplesOperations(backend)
        #expect(asked.count == 2)
    }

    /// **A store the query does not read finishing its build changes nothing** (audit round 4, 2026-10-25): the scope's
    /// own handles decide which readiness transitions matter.
    @Test func an_unrelated_store_finishing_its_build_asks_nothing() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        let handle = Fixture.handle("one")
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [ExamplesFixture.hit], notReady: [handle]) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(await eventually { !model.notReady.isEmpty })
        let before = model.revision
        model.buildStateChanged(ready: [Fixture.handle("elsewhere")])
        #expect(await eventually(awaiting: 2) { await examplesOperations(backend).count == 1 })
        #expect(model.revision == before, "a dictionary this query never asked woke it")
    }

    @Test func the_same_query_over_other_dictionaries_is_asked_again() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [ExamplesFixture.hit]) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(await eventually { model.hits.count == 1 })
        let before = model.revision
        model.update(query: "居然", handles: [Fixture.handle("two")])
        #expect(await eventually { model.revision > before })
        let asked = await examplesOperations(backend)
        #expect(asked.count == 2, "a scope or order change asks again, though the query is the same")
        #expect(asked.last?.dicts == [Fixture.handle("two")])
    }

    /// **The core's own total and cap are kept** (audit round 4): the fixture used to derive the total from the page, so a
    /// wrong total or a dropped cap could not be seen.
    @Test func the_totals_and_the_cap_are_the_cores() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [ExamplesFixture.hit], total: 150, capped: true) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(await eventually { model.hits.count == 1 })
        #expect(model.total == 150)
        #expect(model.capped)
    }

    @Test func the_same_query_over_the_same_dictionaries_keeps_the_answer() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [ExamplesFixture.hit]) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(await eventually { model.hits.count == 1 })
        let revision = model.revision
        let kept = model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(kept, "the same query over the same dictionaries has an answer already")
        #expect(model.revision == revision)
        #expect(await examplesOperations(backend).count == 1)
    }

    @Test func a_pending_query_is_not_reused_as_an_answer() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [ExamplesFixture.hit]) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(await eventually { model.hits.count == 1 })
        #expect(model.update(query: "会", handles: ExamplesFixture.handles()) == false)
        #expect(model.update(query: "会", handles: ExamplesFixture.handles()) == false,
                "the first ask is still out; the previous query's hits are not its answer")
    }

    @Test func a_failed_store_is_known_at_query_time() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        let handle = Fixture.handle("one")
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [], notReady: [handle]) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: [handle], unavailable: [handle])
        #expect(await eventually { !model.notReady.isEmpty })
        #expect(model.failedToPrepare == [handle], "the library's failure is carried into the query, not waited for")
        #expect(model.preparing.isEmpty)
    }

    @Test func every_completed_answer_advances_the_revision() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [ExamplesFixture.hit]) }
        let model = ExamplesModel(backend: backend, window: "test")
        let before = model.revision
        model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(await eventually { model.revision > before })
    }

    @Test func a_failed_store_is_a_failure_not_a_build_still_running() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        let handle = Fixture.handle("one")
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [], notReady: [handle]) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: [handle])
        #expect(await eventually { !model.notReady.isEmpty })
        model.buildStateChanged(ready: [], unavailable: [handle])
        #expect(model.failedToPrepare == [handle])
        #expect(model.preparing.isEmpty)
    }

    @Test func a_failed_query_says_so_and_keeps_no_stale_hits() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [ExamplesFixture.hit]) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(await eventually { model.hits.count == 1 })
        await backend.setAnswer { _ in .failure(.wire(.interrupted)) }
        model.update(query: "会", handles: ExamplesFixture.handles())
        #expect(await eventually { model.failed })
        #expect(model.hits.isEmpty)
        #expect(model.total == 0)
    }

    @Test func the_cjk_test_is_the_cores() {
        #expect(ExamplesModel.hasCJK("居然"))
        #expect(ExamplesModel.hasCJK("誰居然會"))
        #expect(ExamplesModel.hasCJK("𠮷"))
        #expect(!ExamplesModel.hasCJK("run"))
        #expect(!ExamplesModel.hasCJK("abbé"))
    }
}

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

    static func answer(hits: [ExampleHit], notReady: [DictId] = []) -> ClientOutcome {
        .success(Delivered(answer: .examples(Examples(hits: hits, total: UInt64(hits.count), notReady: notReady,
                                                      capped: false)), payload: nil))
    }

    static func handles() -> [DictId] { [Fixture.handle("one")] }
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
    @Test func a_chinese_query_asks_every_dictionary_in_scope() async {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in ExamplesFixture.answer(hits: [ExamplesFixture.hit]) }
        let model = ExamplesModel(backend: backend, window: "test")
        model.update(query: "居然", handles: ExamplesFixture.handles())
        #expect(await eventually { model.hits.count == 1 })
        #expect(model.total == 1)
        #expect(model.hasContent)
        #expect(model.hits[0].chinese == "谁居然会想到这种可能性？")
        let asked = await examplesOperations(backend)
        #expect(asked.count == 1)
        #expect(asked.first?.query == "居然")
        #expect(asked.first?.dicts == [Fixture.handle("one")])
        #expect(asked.first?.limit == ExamplesModel.page)
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
        #expect(model.preparationFailed, "the library's failure is carried into the query, not waited for")
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
        #expect(model.preparationFailed)
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

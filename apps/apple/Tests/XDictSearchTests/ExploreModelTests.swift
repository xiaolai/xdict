import Foundation
import Testing
import XDictClient
import XDictContract
import XDictSearch

/// **The Explore panel's model** (plan-word-exploration WI-3, WI-4): a tab asks for what the core can answer, a tab
/// nothing answers asks for nothing, and a page that cannot be looked for says why instead of showing an empty list.
@MainActor
struct ExploreModelTests {
    nonisolated static let dict = DictId(rawValue: "handle-1")

    nonisolated static func page(_ state: ExploreState, rows: [ExploreRow] = [], cut: Bool = false) -> ClientOutcome {
        .success(Delivered(answer: .explored(ExploreAnswer(state: state, rows: rows, next: nil, exhausted: cut)),
                           payload: nil))
    }

    nonisolated static func backend(_ answer: @escaping @Sendable (ServiceOperation) -> ClientOutcome) async -> FakeSearchBackend {
        let backend = FakeSearchBackend { _, _, _ in .failure(.wire(.interrupted)) }
        await backend.setAnswer(answer)
        return backend
    }

    static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    /// A tab that can answer asks with its own mode and keeps the rows the service sends.
    @Test func aTabAsksWithItsModeAndKeepsItsRows() async {
        let row = ExploreRow(word: "accommodate", dict: Self.dict,
                             entry: EntryRef(edition: Edition(rawValue: "e1"), key: "accommodate", occurrence: 0),
                             reason: .spelling(distance: 1))
        let backend = await Self.backend { _ in Self.page(.answered, rows: [row]) }
        let model = ExploreModel(backend: backend, window: "test")
        model.show(.rhymes, word: "nation", dicts: [Self.dict])
        #expect(await Self.eventually { model.page.rows.count == 1 })
        #expect(model.page.rows.first?.word == "accommodate")
        let asked = await backend.queued.compactMap { queued -> ExploreMode? in
            guard case .explore(_, let mode, _, _, _) = queued.operation else { return nil }
            return mode
        }
        #expect(asked == [.rhyme], "a tab asks for its own mode: \(asked)")
    }

    /// **A tab nothing answers asks nothing**: collocations come from the dictionaries' collocation sections (WI-6),
    /// and a list that cannot exist is not requested.
    @Test func aTabWithoutADataSourceAsksNothingAndClearsThePage() async {
        let backend = await Self.backend { _ in Self.page(.answered) }
        let model = ExploreModel(backend: backend, window: "test")
        model.show(.rhymes, word: "nation", dicts: [Self.dict])
        for _ in 0..<200 where await backend.queued.isEmpty { await Task.yield() }
        model.show(.collocations, word: "nation", dicts: [Self.dict])
        #expect(model.page.rows.isEmpty && !model.page.loading)
        #expect(await backend.queued.count == 1, "only the first tab asked")
    }

    /// **A page that could not look says which state it is in**, and a cut one says so — the shell draws them, the
    /// model never invents rows.
    @Test func theStateAndTheCutCrossToThePanel() async {
        let backend = await Self.backend { _ in Self.page(.noData) }
        let model = ExploreModel(backend: backend, window: "test")
        model.show(.family, word: "possible", dicts: [Self.dict])
        #expect(await Self.eventually { model.page.state == .noData && !model.page.loading })
        #expect(model.page.rows.isEmpty)
    }

    /// An empty scope asks nothing: there is no dictionary to explore.
    @Test func anEmptyScopeAsksNothing() async {
        let backend = await Self.backend { _ in Self.page(.answered) }
        let model = ExploreModel(backend: backend, window: "test")
        model.show(.roots, word: "heart", dicts: [])
        #expect(!model.page.loading)
        #expect(await backend.queued.isEmpty)
    }
}

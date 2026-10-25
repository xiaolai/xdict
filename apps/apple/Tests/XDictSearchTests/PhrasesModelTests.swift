import Foundation
import Synchronization
import Testing
import XDictClient
import XDictContract
import XDictSearch
import XDictTestSupport

private enum PhrasesFixture {
    static let sentence = "the review was full of purple passage nobody could follow"
    static let term = PhraseTerm(location: 30, length: 7)
    static let handles = [Fixture.handle("one")]

    static func match(_ phrase: String = "purple passage", location: UInt64 = 23, length: UInt64 = 14,
                      separation: PhraseSeparation = .none, gap: UInt64 = 0) -> PhraseMatch {
        PhraseMatch(dict: Fixture.handle("one"), phrase: phrase, location: location, length: length,
                    separation: separation, gap: gap)
    }

    static func answer(_ state: PhraseState, matches: [PhraseMatch] = [],
                       coverage: [PhraseCoverageState]? = nil, capped: Bool = false) -> PhraseAnswer {
        let states = coverage ?? [state == .building ? .building : state == .unavailable ? .unavailable : .ready]
        return PhraseAnswer(state: state, matches: matches,
                            coverage: zip(handles, states).map { PhraseCoverage(dict: $0, state: $1) },
                            total: UInt64(matches.count), capped: capped)
    }

    static func outcome(_ answer: PhraseAnswer) -> ClientOutcome {
        .success(Delivered(answer: .phrases(answer), payload: nil))
    }

    static func built() -> ClientOutcome {
        .success(Delivered(answer: .phrasesBuilt(PhrasesBuilt(edition: Fixture.edition("one"), phrases: 3, cached: false)),
                           payload: nil))
    }
}

private func phraseOperations(_ backend: FakeSearchBackend) async -> [(sentence: String, term: PhraseTerm, dicts: [DictId])] {
    await backend.queued.compactMap {
        guard case .phrases(let sentence, let term, let dicts) = $0.operation else { return nil }
        return (sentence, term, dicts)
    }
}

private func buildOperations(_ backend: FakeSearchBackend) async -> [DictId] {
    await backend.queued.compactMap {
        guard case .phrasesBuild(let dict) = $0.operation else { return nil }
        return dict
    }
}

/// **Every answer has its own row** (contract 15; plan-phrase-recognition WI-8): `notAsked` and `none` say nothing,
/// a store still being read and one that could not be are rows of their own, and a found answer shows the core's best
/// candidate with its span.
struct PhraseRowTests {
    @Test func every_state_maps_to_its_own_row() {
        #expect(PhraseRow(nil) == .hidden)
        #expect(PhraseRow(PhrasesFixture.answer(.notAsked)) == .hidden)
        #expect(PhraseRow(PhrasesFixture.answer(.none)) == .hidden)
        #expect(PhraseRow(PhrasesFixture.answer(.building)) == .building)
        #expect(PhraseRow(PhrasesFixture.answer(.unavailable)) == .unavailable)
        #expect(PhraseRow(PhrasesFixture.answer(.found)) == .hidden, "a found answer with no match has nothing to show")
        let found = PhraseRow(PhrasesFixture.answer(.found, matches: [PhrasesFixture.match()], capped: true))
        #expect(found == .found(PhraseRow.Candidate(dict: Fixture.handle("one"), phrase: "purple passage",
                                                    separation: .none, gap: 0, span: NSRange(location: 23, length: 14)),
                                total: 1, capped: true))
    }

    /// The separation is carried as the publisher's or the matcher's own, never flattened to "a phrase".
    @Test func the_separation_survives_the_row() throws {
        for (separation, gap) in [(PhraseSeparation.marked(words: 2), UInt64(2)),
                                  (PhraseSeparation.inferred(words: 2), UInt64(2)),
                                  (PhraseSeparation.none, UInt64(0))] {
            let row = PhraseRow(PhrasesFixture.answer(.found, matches: [
                PhrasesFixture.match(separation: separation, gap: gap),
            ]))
            guard case .found(let candidate, _, _) = row else {
                Issue.record("no candidate: \(row)")
                return
            }
            #expect(candidate.separation == separation && candidate.gap == gap)
        }
    }

    /// The span is clamped to what the sentence holds: a promise the row did not check never traps its drawing.
    @Test func the_span_is_clamped_to_its_sentence() {
        let candidate = PhraseRow.Candidate(dict: Fixture.handle("one"), phrase: "passage", separation: .none, gap: 0,
                                            span: NSRange(location: 30, length: 7))
        let sentence = "the review was full of purple passage"
        let span = PhrasesModel.span(candidate, in: sentence)
        #expect(span.map { String(sentence[$0]) } == "passage")
        let beyond = PhraseRow.Candidate(dict: candidate.dict, phrase: candidate.phrase, separation: .none, gap: 0,
                                         span: NSRange(location: 40, length: 7))
        #expect(PhrasesModel.span(beyond, in: sentence) == nil)
        let empty = PhraseRow.Candidate(dict: candidate.dict, phrase: candidate.phrase, separation: .none, gap: 0,
                                        span: NSRange(location: 3, length: 0))
        #expect(PhrasesModel.span(empty, in: sentence) == nil)
    }
}

/// **The phrase a capture asks about** (contract 15; plan WI-8): one question per sentence, the building store built
/// once and the question asked again, and a late answer to an older capture dropped.
@MainActor
struct PhrasesModelTests {
    private func model(_ backend: FakeSearchBackend) -> PhrasesModel {
        PhrasesModel(backend: backend, window: "test")
    }

    @Test func a_capture_asks_once_and_shows_the_best_candidate() async throws {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in
            PhrasesFixture.outcome(PhrasesFixture.answer(.found, matches: [PhrasesFixture.match()]))
        }
        let phrases = model(backend)
        phrases.update(sentence: PhrasesFixture.sentence, term: PhrasesFixture.term, handles: PhrasesFixture.handles)
        #expect(await eventually { if case .found = phrases.row { true } else { false } })
        #expect(phrases.sentence == PhrasesFixture.sentence)
        let asked = await phraseOperations(backend)
        #expect(asked.count == 1)
        #expect(asked.first?.sentence == PhrasesFixture.sentence)
        #expect(asked.first?.term == PhrasesFixture.term)
        #expect(asked.first?.dicts == PhrasesFixture.handles)

        // The same question again, while its answer stands, asks nothing more.
        phrases.update(sentence: PhrasesFixture.sentence, term: PhrasesFixture.term, handles: PhrasesFixture.handles)
        #expect(await phraseOperations(backend).count == 1)
    }

    /// **`building` never looks like `none`**: the store is built once through the service, and the question is asked
    /// again — the row ends on the phrase, not on a spinner.
    @Test func a_building_store_is_built_then_asked_again() async throws {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        let stored = Mutex(false)
        await backend.setAnswer { operation in
            switch operation {
            case .phrases:
                let ready = stored.withLock { $0 }
                return PhrasesFixture.outcome(ready
                    ? PhrasesFixture.answer(.found, matches: [PhrasesFixture.match()])
                    : PhrasesFixture.answer(.building))
            case .phrasesBuild:
                stored.withLock { $0 = true }
                return PhrasesFixture.built()
            default:
                return .failure(.wire(.interrupted))
            }
        }
        let phrases = model(backend)
        phrases.update(sentence: PhrasesFixture.sentence, term: PhrasesFixture.term, handles: PhrasesFixture.handles)
        #expect(await eventually { if case .found = phrases.row { true } else { false } })
        #expect(await buildOperations(backend) == PhrasesFixture.handles, "one build, for the dictionary that was not ready")
        #expect(await phraseOperations(backend).count == 2, "asked again after the build")
    }

    /// **A late answer to an older capture changes nothing**: the newer sentence's answer is the row, whatever order
    /// the two replies arrive in.
    @Test func a_late_answer_to_an_older_capture_is_dropped() async throws {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.holdPhrases()
        await backend.setAnswer { operation in
            guard case .phrases(let sentence, _, _) = operation else { return .failure(.wire(.interrupted)) }
            return PhrasesFixture.outcome(sentence == PhrasesFixture.sentence
                ? PhrasesFixture.answer(.found, matches: [PhrasesFixture.match()])
                : PhrasesFixture.answer(.found, matches: [PhrasesFixture.match("red herring", location: 19, length: 11)]))
        }
        let phrases = model(backend)
        phrases.update(sentence: PhrasesFixture.sentence, term: PhrasesFixture.term, handles: PhrasesFixture.handles)
        #expect(await eventually(awaiting: 2) { await backend.heldPhrases.contains(PhrasesFixture.sentence) })
        let newer = "that argument is a red herring"
        phrases.update(sentence: newer, term: PhraseTerm(location: 19, length: 3), handles: PhrasesFixture.handles)
        #expect(await eventually(awaiting: 2) { await backend.heldPhrases.contains(newer) })
        // The older capture answers last.
        await backend.releasePhrases(newer)
        #expect(await eventually { phrases.row == PhraseRow(PhrasesFixture.answer(
            .found, matches: [PhrasesFixture.match("red herring", location: 19, length: 11)])) })
        await backend.releasePhrases(PhrasesFixture.sentence)
        try await Task.sleep(for: .milliseconds(50))
        guard case .found(let candidate, _, _) = phrases.row else {
            Issue.record("no candidate: \(phrases.row)")
            return
        }
        #expect(candidate.phrase == "red herring", "the older capture's answer replaced the newer one")
        #expect(phrases.sentence == newer)
    }

    /// **A dictionary set that changed is a new question** (WI-7's "disabled mid-request"): the model asks over the
    /// handles it is given, so the next capture after an enable or a disable never answers from the old set.
    @Test func a_changed_dictionary_set_asks_again() async throws {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in
            PhrasesFixture.outcome(PhrasesFixture.answer(.found, matches: [PhrasesFixture.match()]))
        }
        let phrases = model(backend)
        phrases.update(sentence: PhrasesFixture.sentence, term: PhrasesFixture.term, handles: PhrasesFixture.handles)
        #expect(await eventually { if case .found = phrases.row { true } else { false } })
        let pair = PhrasesFixture.handles + [Fixture.handle("two")]
        phrases.update(sentence: PhrasesFixture.sentence, term: PhrasesFixture.term, handles: pair)
        #expect(await eventually(awaiting: 2) { await phraseOperations(backend).count == 2 })
        #expect(await phraseOperations(backend).last?.dicts == pair)
    }

    /// **A question that failed says so** (audit round 1, 2026-10-26): the row is `unavailable`, never a "still
    /// reading" that would wait for a build that is not coming.
    @Test func a_failed_question_is_unavailable() async throws {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in .failure(.wire(.interrupted)) }
        let phrases = model(backend)
        phrases.update(sentence: PhrasesFixture.sentence, term: PhrasesFixture.term, handles: PhrasesFixture.handles)
        #expect(await eventually { phrases.row == .unavailable })
    }

    /// **A failed question is asked again on the next capture** (audit round 2, 2026-10-26): `unavailable` is the row
    /// while it stands, never the answer for that sentence for good.
    @Test func a_failed_question_can_be_asked_again() async throws {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        let attempts = Mutex(0)
        await backend.setAnswer { _ in
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            return attempt == 1
                ? .failure(.wire(.interrupted))
                : PhrasesFixture.outcome(PhrasesFixture.answer(.found, matches: [PhrasesFixture.match()]))
        }
        let phrases = model(backend)
        phrases.update(sentence: PhrasesFixture.sentence, term: PhrasesFixture.term, handles: PhrasesFixture.handles)
        #expect(await eventually { phrases.row == .unavailable })
        phrases.update(sentence: PhrasesFixture.sentence, term: PhrasesFixture.term, handles: PhrasesFixture.handles)
        #expect(await eventually { if case .found = phrases.row { true } else { false } })
        #expect(await phraseOperations(backend).count == 2, "the failure was cached as the answer")
    }

    /// **A dictionary is built once, however many captures arrive while its build runs** (audit round 2, 2026-10-26):
    /// the second capture awaits the running build instead of queueing another, and the row still ends on the phrase.
    @Test func a_second_capture_waits_for_the_running_build() async throws {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        let stored = Mutex(false)
        await backend.setAnswer { operation in
            switch operation {
            case .phrases:
                let ready = stored.withLock { $0 }
                return PhrasesFixture.outcome(ready
                    ? PhrasesFixture.answer(.found, matches: [PhrasesFixture.match()])
                    : PhrasesFixture.answer(.building))
            case .phrasesBuild:
                stored.withLock { $0 = true }
                return PhrasesFixture.built()
            default:
                return .failure(.wire(.interrupted))
            }
        }
        await backend.hold(Fixture.handle("one"))
        let phrases = model(backend)
        phrases.update(sentence: PhrasesFixture.sentence, term: PhrasesFixture.term, handles: PhrasesFixture.handles)
        #expect(await eventually(awaiting: 2) { await buildOperations(backend).count == 1 }, "the build is out")
        let second = "purple passage was the phrase that mattered"
        phrases.update(sentence: second, term: PhraseTerm(location: 0, length: 6), handles: PhrasesFixture.handles)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await buildOperations(backend).count == 1, "the running build is awaited, not started again")
        await backend.release(Fixture.handle("one"))
        #expect(await eventually { if case .found = phrases.row { true } else { false } },
                "the row ends on a phrase, not on a spinner: \(phrases.row)")
        #expect(phrases.sentence == second)
        #expect(await buildOperations(backend).count == 1, "the build was not started again after it finished")
    }

    /// **The sentence is kept exactly as captured**: its leading whitespace stays, because the term's range counts
    /// UTF-16 units of this very string.
    @Test func the_sentence_is_kept_as_captured() async throws {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in
            PhrasesFixture.outcome(PhrasesFixture.answer(.found, matches: [PhrasesFixture.match()]))
        }
        let phrases = model(backend)
        let sentence = "  " + PhrasesFixture.sentence
        phrases.update(sentence: sentence, term: PhraseTerm(location: 32, length: 7), handles: PhrasesFixture.handles)
        #expect(await eventually { if case .found = phrases.row { true } else { false } })
        #expect(phrases.sentence == sentence)
        #expect(await phraseOperations(backend).first?.sentence == sentence)
    }

    @Test func clearing_hides_the_row() async throws {
        let backend = FakeSearchBackend { _, _, _ in .success(Fixture.page([])) }
        await backend.setAnswer { _ in
            PhrasesFixture.outcome(PhrasesFixture.answer(.found, matches: [PhrasesFixture.match()]))
        }
        let phrases = model(backend)
        phrases.update(sentence: PhrasesFixture.sentence, term: PhrasesFixture.term, handles: PhrasesFixture.handles)
        #expect(await eventually { if case .found = phrases.row { true } else { false } })
        phrases.clear()
        #expect(phrases.row == .hidden && phrases.sentence.isEmpty)
    }
}

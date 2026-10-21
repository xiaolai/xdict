import Foundation
import Testing
import XDictClient
import XDictContract

/// **The study calls through the real service** (contract 10; plan-history-and-learning §5): a note enrols an entry, the
/// queue shows it, a grade schedules it under the reader's configuration, an undo voids it, and a retry of the same
/// operation settles to the original answer instead of grading twice.
struct StudyServiceTests {
    /// 2026-09-29 00:00 UTC.
    static let now: Double = 1_790_640_000
    static let stamp = StudyStamp(at: now, device: "test")
    static let policy = StudyPolicy(retention: 0.9, maximumDays: 36_500)

    static func opened() async throws -> (ServiceHarness, ServiceClient, DictId, EntryRef)? {
        let harness = try ServiceHarness()
        let dir = try ServiceHarness.fixtures().appending(path: "tiny")
        try #require(FileManager.default.fileExists(atPath: dir.appending(path: "tiny.mdx").path),
                     "no tiny fixture: run `make test`, or Tools/build-fixtures.sh .build/fixtures")
        let client = harness.client()
        let package = DictionaryPackage.of(mdx: dir.appending(path: "tiny.mdx"), volumes: [], sidecars: [])
        guard case .success(let imported) = await client.importPackage(package),
              case .success(.ready(let dict, _, _)) = await client.open(package) else {
            Issue.record("the tiny fixture did not import and open")
            return nil
        }
        return (harness, client, dict, EntryRef(edition: imported.edition, key: "run", occurrence: 0))
    }

    static func outcome(_ result: ClientOutcome) -> StudyOutcome? {
        guard case .success(let delivered) = result, case .reviewOutcome(let outcome) = delivered.answer else {
            return nil
        }
        return outcome
    }

    @Test func aNoteIsQueuedGradedAndUndoneAndARetrySettlesToTheOriginal() async throws {
        let opened = try #require(try await Self.opened())
        let (_, client, dict, ref) = opened

        let hashOutcome = await client.call(.definitionHash(dict: dict, entry: ref))
        guard case .success(let delivered) = hashOutcome, case .definitionHash(let hash) = delivered.answer else {
            Issue.record("no definition hash: \(hashOutcome)")
            return
        }
        #expect(!hash.isEmpty)

        let saved = await client.call(.studyNote(dict: dict, entry: ref, text: "my own words", name: "Tiny",
                                                 stamp: Self.stamp, operation: "note-1"))
        guard case .success(let noted) = saved, case .studyNote(let note) = noted.answer else {
            Issue.record("no note: \(saved)")
            return
        }
        #expect(note.text == "my own words", "the note is the reader's words")
        #expect(note.target.definitionHash == hash, "the evidence is the definition's hash")
        #expect(!note.target.lineage.isEmpty, "the ledger owns the association")

        let listed = await client.call(.studyNotes)
        guard case .success(let notes) = listed, case .studyNotes(let all) = notes.answer else {
            Issue.record("no notes: \(listed)")
            return
        }
        #expect(all.count == 1)

        let queued = await client.call(.reviewQueue(now: Self.now, limit: 10))
        guard case .success(let shown) = queued, case .reviewQueue(let cards) = shown.answer else {
            Issue.record("no queue: \(queued)")
            return
        }
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(card.state.isNew)
        let key = card.target.key

        let graded = try #require(Self.outcome(await client.call(
            .reviewGrade(target: key, revision: "", grade: .good, policy: Self.policy, stamp: Self.stamp,
                         operation: "grade-1"))))
        #expect(graded.outcome == .recorded)
        #expect(!graded.card.state.isNew)
        #expect((graded.card.state.due ?? 0) > Self.now)

        let summaryResult = await client.call(.reviewSummary(now: Self.now))
        guard case .success(let summary) = summaryResult, case .reviewSummary(let report) = summary.answer else {
            Issue.record("no summary: \(summaryResult)")
            return
        }
        #expect(report.due == 0, "the only card is scheduled")
        #expect(report.nextDue == UInt64(graded.card.state.due ?? 0))

        // A retry of the committed grade is the original operation: it settles to `duplicate`, not to a second grade.
        let retry = try #require(Self.outcome(await client.call(
            .reviewGrade(target: key, revision: "", grade: .good, policy: Self.policy, stamp: Self.stamp,
                         operation: "grade-1"))))
        #expect(retry.outcome == .duplicate)
        #expect(!retry.card.state.isNew, "the card is still the graded one")

        let undone = try #require(Self.outcome(await client.call(
            .reviewUndo(target: key, gradeEvent: graded.card.head, stamp: Self.stamp, operation: "undo-1"))))
        #expect(undone.outcome == .recorded)
        #expect(undone.card.state.isNew, "the grade is voided")
        #expect(undone.card.head.isEmpty)
    }

    @Test func aRetryOfACommittedNoteIsOneNote() async throws {
        let opened = try #require(try await Self.opened())
        let (_, client, dict, ref) = opened
        for operation in ["note", "note"] {
            let result = await client.call(.studyNote(dict: dict, entry: ref, text: "mine", name: "Tiny",
                                                      stamp: Self.stamp, operation: operation))
            guard case .success(let delivered) = result, case .studyNote = delivered.answer else {
                Issue.record("no note: \(result)")
                return
            }
        }
        let listed = await client.call(.studyNotes)
        guard case .success(let notes) = listed, case .studyNotes(let all) = notes.answer else {
            Issue.record("no notes: \(listed)")
            return
        }
        #expect(all.count == 1, "the same operation and the same note is one event")
    }
}

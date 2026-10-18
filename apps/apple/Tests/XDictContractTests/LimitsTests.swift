import Foundation
import Testing
import XDictContract

/// The numbers the contract fixes, each held to the measurement or the core constant it was taken from.
struct LimitsTests {
    /// The core's own ceiling (`MAX_RESOURCE_BYTES` = one reader block, 64 MiB, `core.rs`), carried whole (spike 2).
    @Test func aResourceMayBeTheCoresWholeBlock() {
        #expect(Limits.maxResourceBytes == 64 * 1_024 * 1_024)
    }

    /// 16 MiB: five times the largest record in the 25 (OED, 3,344,260 bytes; spike 2), so the rewrite has room.
    @Test func aBodyMayBeFiveTimesTheLargestRealRecord() {
        #expect(Limits.maxBodyBytes == 16 * 1_024 * 1_024)
        #expect(Limits.maxBodyBytes >= 5 * 3_344_260)
        #expect(Limits.maxBodyBytes < Limits.maxResourceBytes)
    }

    @Test func entriesAndResourcesAreTheBulkCallsAndTwoMayRun() {
        #expect(Limits.bulkCallsInFlight == 2)
        let bulk = Fixtures.operations.filter(\.isBulk).map(Fixtures.index)
        #expect(Set(bulk) == [Fixtures.index(.entry(dict: Fixtures.dict, entry: Fixtures.entryRef, render: .reader)),
                              Fixtures.index(.resource(dict: Fixtures.dict, path: "a", render: .reader))])
    }

    /// Only an answer that carries a payload has a ceiling: an entry's is the view's, a resource's by its type.
    @Test func onlyAnswersWithAPayloadHaveACeiling() {
        let render = RenderContext(maxBodyBytes: 1_000)
        let entry = ServiceOperation.entry(dict: Fixtures.dict, entry: Fixtures.entryRef, render: render)
        let resource = ServiceOperation.resource(dict: Fixtures.dict, path: "a", render: render)
        for answer in Fixtures.answers {
            let operation = answer.answers(entry) ? entry : resource
            #expect((Limits.payloadCeiling(for: operation, answer: answer) != nil) == answer.carriesPayload, "\(answer)")
        }
        #expect(Limits.payloadCeiling(for: entry, answer: .entry(Entry(entry: Fixtures.entryRef, csp: "", lossyBytes: 0))) == 1_000)
        #expect(Limits.payloadCeiling(for: resource, answer: .resource(.found(path: "a.css", mime: "text/css"))) == 1_000)
        #expect(Limits.payloadCeiling(for: resource, answer: .resource(.found(path: "a.mp3", mime: "audio/mpeg")))
                == Limits.maxResourceBytes)
        #expect(Limits.payloadCeiling(for: resource, answer: .resource(.missing(path: "a"))) == nil)
    }

    /// The bounds Codex objection 2 asked for, each from what it protects.
    @Test func theServicesWorkIsBounded() {
        #expect(Limits.maxEnvelopeBytes == 4 << 20)
        #expect(Limits.maxPackageFiles == 64)
        #expect(Limits.maxSuggestions == 100)
        #expect(Limits.lookupCallsInFlight == 4)
        let lookups = Fixtures.operations.filter { $0.creditClass == .lookup }.map(Fixtures.index)
        #expect(Set(lookups) == [Fixtures.index(.openPackage(spec: Fixtures.package)),
                                 Fixtures.index(.lookup(query: "", dicts: [], options: LookupOptions(limit: 1, offset: 0, mode: .reader, generation: nil))),
                                 Fixtures.index(.suggest(prefix: "", dicts: [], limit: 1)),
                                 Fixtures.index(.link(dict: Fixtures.dict, url: "", origin: .resource(path: ""), render: .reader))])
        for operation in Fixtures.operations {
            #expect((operation.creditClass == .bulk) == operation.isBulk, "\(operation)")
        }
    }

    /// The envelope ceiling's justification, run: a page of 1,000 hits, each reached through a redirect chain at the
    /// core's hop limit (8 hops, 9 keys) of 100-character keys and carrying a redirect-limit problem of the same chain,
    /// fits under `Limits.maxEnvelopeBytes` with room.
    @Test func aFullPageOfTheLongestHitsFits() throws {
        let key = { (n: Int) in String(repeating: "k", count: 96) + String(format: "%04d", n) }
        let chain = (0..<9).map(key)
        let hit = Hit(dict: Fixtures.dict, entry: EntryRef(edition: Fixtures.edition, key: key(9), occurrence: 7),
                      headword: key(10), how: .redirect(chain: chain), problems: [.redirectLimit(chain: chain)])
        let page = Page(hits: Array(repeating: hit, count: 1_000), total: 66_355, generation: 1, problems: [])
        let bytes = try Response(id: .max, outcome: .answer(.page(page))).encoded().count
        #expect(bytes < Int(Limits.maxEnvelopeBytes) * 3 / 4, "\(bytes) bytes")
        #expect(bytes > 2_000_000, "the estimate in `maxEnvelopeBytes`'s comment is off: \(bytes) bytes")
    }

    // MARK: - Credits, per connection (Codex objections 2 and 11)

    /// Two bulk calls and four lookup-class calls at once on one connection; the next of either is refused, and a
    /// released credit admits one more. Calls with no credit class are never refused for numbers.
    @Test func aConnectionsCreditsBoundWhatRunsAtOnce() throws {
        var credits = Credits()
        let resource = ServiceOperation.resource(dict: Fixtures.dict, path: "a", render: .reader)
        let lookup = ServiceOperation.suggest(prefix: "a", dicts: [Fixtures.dict], limit: 1)
        let bulk = try (0..<Limits.bulkCallsInFlight).map { _ in try credits.take(for: resource).get() }
        #expect(credits.take(for: resource) == .failure(.tooManyInFlight))
        let looks = try (0..<Limits.lookupCallsInFlight).map { _ in try credits.take(for: lookup).get() }
        #expect(credits.take(for: lookup) == .failure(.tooManyInFlight))
        for operation: ServiceOperation in [.versions, .close(dict: Fixtures.dict), .importPackage(spec: Fixtures.package)] {
            #expect((try? credits.take(for: operation).get()) != nil, "\(operation)")
        }
        credits.release(bulk[0])
        #expect((try? credits.take(for: resource).get()) != nil)
        credits.release(looks[0])
        #expect((try? credits.take(for: lookup).get()) != nil)
        #expect(credits.inFlight(.bulk) == Limits.bulkCallsInFlight && credits.inFlight(.lookup) == Limits.lookupCallsInFlight)
    }

    /// Credits belong to a connection: a new connection starts with all of them, whatever the old one holds.
    @Test func aNewConnectionStartsWithEveryCredit() throws {
        var old = Credits(), fresh = Credits()
        let resource = ServiceOperation.resource(dict: Fixtures.dict, path: "a", render: .reader)
        _ = try (0..<Limits.bulkCallsInFlight).map { _ in try old.take(for: resource).get() }
        #expect(old.take(for: resource) == .failure(.tooManyInFlight))
        #expect((try? fresh.take(for: resource).get()) != nil)
    }

    /// **A credited call past its deadline costs its connection** (Codex objection 11): its credit is held until the
    /// service answers, which may be never, so the client abandons the connection and opens another, whose credits
    /// are whole. Calls holding no credit fail alone.
    @Test func aCreditedCallPastItsDeadlineAbandonsItsConnection() {
        for operation in Fixtures.operations {
            #expect(Deadlines.abandonsConnectionOnExpiry(operation) == (operation.creditClass != nil), "\(operation)")
        }
    }

    /// Every operation has a deadline but the import and the health check, which are bounded by silence instead.
    @Test func everyOperationButImportHasADeadline() {
        for operation in Fixtures.operations {
            let deadline = Deadlines.deadline(for: operation, onFreshConnection: false)
            if operation.reportsProgress {
                #expect(deadline == nil)
            } else {
                #expect(deadline.map { $0 > .zero && $0 <= .seconds(15) } == true, "\(operation): no deadline in (0, 15 s]")
            }
        }
        #expect(Deadlines.importSilence == .seconds(60))
    }

    @Test func theDeadlinesAreTheChosenOnes() {
        let deadline = { Deadlines.deadline(for: $0, onFreshConnection: false) }
        #expect(deadline(.versions) == .seconds(2))
        #expect(deadline(.close(dict: Fixtures.dict)) == .seconds(2))
        #expect(deadline(.cancel(request: 1)) == .seconds(2))
        #expect(deadline(.openPackage(spec: Fixtures.package)) == .seconds(5))
        #expect(deadline(.lookup(query: "a", dicts: [], options: LookupOptions(limit: 1, offset: 0, mode: .reader,
                                                                                generation: nil))) == .seconds(5))
        #expect(deadline(.suggest(prefix: "a", dicts: [], limit: 1)) == .seconds(5))
        #expect(deadline(.link(dict: Fixtures.dict, url: "a", origin: .resource(path: "a"), render: .reader)) == .seconds(5))
        #expect(deadline(.joinLineage(edition: Fixtures.edition, lineage: Fixtures.lineage)) == .seconds(5))
        #expect(deadline(.splitLineage(edition: Fixtures.edition, newLineage: Fixtures.newLineage)) == .seconds(5))
        #expect(deadline(.lineageOf(edition: Fixtures.edition)) == .seconds(5))
        #expect(deadline(.entry(dict: Fixtures.dict, entry: Fixtures.entryRef, render: .reader)) == .seconds(10))
        #expect(deadline(.resource(dict: Fixtures.dict, path: "a", render: .reader)) == .seconds(15))
    }

    /// The first call on a new connection starts the service: it waits at least the cold-start allowance, and a call
    /// whose own deadline is longer keeps it. The import stays unbounded.
    @Test func theFirstCallOnANewConnectionWaitsForTheServiceToStart() {
        #expect(Deadlines.coldStart == .seconds(10))
        #expect(Deadlines.deadline(for: .versions, onFreshConnection: true) == .seconds(10))
        #expect(Deadlines.deadline(for: .resource(dict: Fixtures.dict, path: "a", render: .reader), onFreshConnection: true)
                == .seconds(15))
        #expect(Deadlines.deadline(for: .importPackage(spec: Fixtures.package), onFreshConnection: true) == nil)
    }

    /// WI-12: a health check reads every record of an edition, so like an import it has no deadline, is bounded by the
    /// silence between its progress events, holds no credit, and names the dictionary whose files it reads.
    @Test func aHealthCheckIsBoundedBySilenceLikeAnImport() {
        let health = ServiceOperation.health(dict: Fixtures.dict)
        #expect(Deadlines.deadline(for: health, onFreshConnection: false) == nil)
        #expect(health.reportsProgress && ServiceOperation.importPackage(spec: Fixtures.package).reportsProgress)
        #expect(!ServiceOperation.lookup(query: "a", dicts: [], options: LookupOptions(limit: 1, offset: 0, mode: .reader,
                                                                                         generation: nil)).reportsProgress)
        #expect(health.creditClass == nil && !health.isBulk && health.packageSpec == nil)
    }

    /// ADR-0010 (owner's decision of 2026-10-17; contract 4): the reading style's report of an open dictionary is one
    /// short call with a deadline, holding no credit, reading the files of the dictionary it names.
    @Test func aReadingStyleReportIsAShortCallOnTheNamedDictionary() {
        let report = ServiceOperation.readingStyle(dict: Fixtures.dict)
        #expect(Deadlines.deadline(for: report, onFreshConnection: false) == .seconds(15))
        #expect(!report.reportsProgress && report.creditClass == nil && !report.isBulk && report.packageSpec == nil)
        #expect(report.render == nil)
    }
}

import Foundation
import Testing
import XDictClient
import XDictContract
@testable import XDictService

/// **Conversions through the real service** (ADR-0011 decision 5; plan WI-4): over a real NSXPC connection, one at a
/// time across the service, cancellable by the client and by its disconnection, and never in the way of a lookup.
struct AppleImportConnectionTests {
    static func converted(_ outcome: ClientOutcome) -> Converted? {
        guard case .success(let delivered) = outcome, case .converted(let converted) = delivered.answer else { return nil }
        return converted
    }

    @Test func aStagedSnapshotIsConvertedThroughTheContract() async throws {
        let staging = try AppleStaging()
        let harness = try ServiceHarness(appleImports: staging.store)
        let id = try staging.stage()
        let reports = ReportLog()
        let client = harness.client()
        let outcome = await client.submitConvertApple(staging: id) { reports.add($0, $1) }.outcome()
        let converted = try #require(Self.converted(outcome), "\(outcome)")
        #expect(converted.entries == 2 && converted.files == ["dictionary.mdx", "dictionary.mdd"])
        #expect(!reports.all.isEmpty, "progress reached the client")
        #expect(staging.leftovers == [converted.conversion.uuidString])
    }

    /// A service with no app-group container (unsigned, or without the entitlement) refuses by kind.
    @Test func aServiceWithoutItsContainerRefuses() async throws {
        let harness = try ServiceHarness(appleImports: nil)
        let client = harness.client()
        let outcome = await client.submitConvertApple(staging: UUID()).outcome()
        #expect(outcome == .failure(.wire(.appleImport(.noContainer))))
    }

    @Test func twoConversionsRunOneAfterTheOther() async throws {
        let hold = StepHold()
        let staging = try AppleStaging(onStep: hold.onStep)
        let harness = try ServiceHarness(appleImports: staging.store)
        let client = harness.client()
        let first = await client.submitConvertApple(staging: try staging.stage())
        #expect(await hold.waitUntilHeld())
        let second = await client.submitConvertApple(staging: try staging.stage())
        #expect(await eventually { harness.context.conversions.load == (running: 1, waiting: 1) },
                "the second waits for the first: \(harness.context.conversions.load)")
        hold.letGo()
        let one = try #require(Self.converted(await first.outcome()))
        let two = try #require(Self.converted(await second.outcome()))
        #expect(one.conversion != two.conversion)
        #expect(staging.leftovers.sorted() == [one.conversion.uuidString, two.conversion.uuidString].sorted())
    }

    /// A conversion waiting its turn still reports, so the client's silence deadline (`Deadlines.importSilence`) does
    /// not end it while another, however long, runs ahead of it.
    @Test func aWaitingConversionKeepsReporting() async throws {
        let hold = StepHold()
        let staging = try AppleStaging(onStep: hold.onStep)
        let harness = try ServiceHarness(appleImports: staging.store, conversionHeartbeat: .milliseconds(50))
        let client = harness.client()
        let first = await client.submitConvertApple(staging: try staging.stage())
        #expect(await hold.waitUntilHeld())
        let reports = ReportLog()
        let second = await client.submitConvertApple(staging: try staging.stage()) { reports.add($0, $1) }
        #expect(await eventually { reports.all.count >= 3 }, "heard while waiting: \(reports.all)")
        #expect(harness.context.conversions.load.waiting == 1, "and still waiting")
        hold.letGo()
        let one = await first.outcome(), two = await second.outcome()
        #expect(Self.converted(one) != nil && Self.converted(two) != nil, "\(one), \(two)")
    }

    /// Lookups keep their own gates: one is answered while a conversion runs (ADR-0011 decision 5).
    @Test func aLookupIsAnsweredDuringAConversion() async throws {
        let hold = StepHold()
        let staging = try AppleStaging(onStep: hold.onStep)
        let harness = try ServiceHarness(appleImports: staging.store)
        let client = harness.client()
        let conversion = await client.submitConvertApple(staging: try staging.stage())
        #expect(await hold.waitUntilHeld())
        let dir = try ServiceHarness.fixtures().appending(path: "tiny")
        let package = DictionaryPackage.of(mdx: dir.appending(path: "tiny.mdx"), volumes: [dir.appending(path: "tiny.mdd")],
                                           sidecars: [dir.appending(path: "tiny.css")])
        guard case .success = await client.importPackage(package),
              case .success(.ready(let dict, _, _)) = await client.open(package) else {
            hold.letGo()
            Issue.record("the tiny fixture did not import and open during the conversion")
            return
        }
        let lookup = await client.call(.lookup(query: "hold", dicts: [dict], options: LookupOptions(
            limit: 10, offset: 0, mode: .reader, generation: nil)))
        guard case .success(let delivered) = lookup, case .page = delivered.answer else {
            hold.letGo()
            Issue.record("no lookup answer during the conversion: \(lookup)")
            return
        }
        #expect(harness.context.conversions.load.running == 1, "the conversion was still running")
        hold.letGo()
        #expect(Self.converted(await conversion.outcome()) != nil)
    }

    @Test func theClientCancelsItsConversion() async throws {
        let hold = StepHold()
        let staging = try AppleStaging(onStep: hold.onStep)
        let harness = try ServiceHarness(appleImports: staging.store)
        let client = harness.client()
        let ticket = await client.submitConvertApple(staging: try staging.stage())
        #expect(await hold.waitUntilHeld())
        #expect(await client.cancelConversion(ticket) == .success(.stopping))
        hold.letGo()
        guard case .failure(.wire(.core(.cancelled))) = await ticket.outcome() else {
            Issue.record("the conversion was not cancelled")
            return
        }
        #expect(await eventually { staging.leftovers.isEmpty }, "\(staging.leftovers)")
    }

    // MARK: - A client that goes

    /// A raw connection, so the test can drop it with a conversion in flight.
    static func send(_ operation: ServiceOperation, on harness: ServiceHarness) throws -> any ServiceConnection {
        let connection = harness.connect(ConnectionEvents(interrupted: {}, invalidated: {}, event: { _ in }))
        connection.send(try Request(id: 1, tokens: [], operation: operation).encoded(), files: nil) { _ in }
        return connection
    }

    @Test func aClientThatGoesCancelsItsRunningConversion() async throws {
        let hold = StepHold()
        let staging = try AppleStaging(onStep: hold.onStep)
        let harness = try ServiceHarness(appleImports: staging.store)
        let connection = try Self.send(.convertApple(staging: try staging.stage()), on: harness)
        #expect(await hold.waitUntilHeld())
        connection.invalidate()
        // The service hears the invalidation on NSXPC's queue; the conversion is held until then and some time after.
        try await Task.sleep(for: .seconds(1))
        hold.letGo()
        #expect(await eventually { harness.context.conversions.load == (running: 0, waiting: 0) && staging.leftovers.isEmpty },
                "cancelled, and nothing left: \(staging.leftovers)")
    }

    @Test func aClientThatGoesWhileItsConversionWaitsNeverHasItRun() async throws {
        let hold = StepHold()
        let staging = try AppleStaging(onStep: hold.onStep)
        let harness = try ServiceHarness(appleImports: staging.store)
        let client = harness.client()
        let first = await client.submitConvertApple(staging: try staging.stage())
        #expect(await hold.waitUntilHeld())
        let waiting = try staging.stage()
        let connection = try Self.send(.convertApple(staging: waiting), on: harness)
        #expect(await eventually { harness.context.conversions.load.waiting == 1 })
        connection.invalidate()
        #expect(await eventually { harness.context.conversions.load.waiting == 0 && !staging.leftovers.contains("staging/\(waiting.uuidString)") },
                "dropped, its staging removed: \(staging.leftovers)")
        hold.letGo()
        let converted = try #require(Self.converted(await first.outcome()))
        #expect(await eventually { staging.leftovers == [converted.conversion.uuidString] }, "\(staging.leftovers)")
    }
}

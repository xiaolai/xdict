import Foundation
import Synchronization
import Testing
@testable import XDictCapture

/// **The sentence reaches no consumer** (ADR-0014 decision 9; `CONTRACT.md` §6; plan-capture WI-5): a canary sentence
/// travels through a delivery, a settlement, a cancellation, a replacement and the refusal path; every string a consumer
/// would hold — the sink's (search, the service, the trail, the observation hooks), the book's acknowledgements, and
/// every description, debug description and mirror of the capture values — is inspected for the canary's marker. The
/// session is the one holder, and the control below proves the marker is real, so a scan that saw nothing says so.
struct CapturePrivacyCanaryTests {
    /// Inside the sentence, never in the term: what a leak would carry and what a scan looks for.
    static let marker = "CANARY-9f3c"
    static let sentence = "\(marker) the hollow moon drifted over the harbour while nobody watched."
    static let term = "harbour"

    /// What the app's consumers record: the term and the metadata, never the context. A sink that kept the whole
    /// `CapturedTerm` would keep the sentence, which is why the app hands it to the session and records only this.
    private final class Consumer: CaptureSink {
        private let strings = Mutex<[String]>([])
        let refused: Bool

        init(refused: Bool = false) { self.refused = refused }

        func deliver(_ delivery: CaptureDelivery) -> CaptureDeliveryAnswer {
            strings.withLock {
                $0 += [delivery.term.term, String(delivery.request.number), String(delivery.generation),
                       delivery.request.trigger.rawValue, String(describing: delivery.request),
                       String(describing: delivery), String(reflecting: delivery)]
            }
            return refused ? .refused : .accepted
        }

        var recorded: [String] { strings.withLock { $0 } }
    }

    private func term(_ word: String = Self.term, sentence: String = Self.sentence,
                      context: ContextOutcome? = nil) throws -> CapturedTerm {
        let outcome = context ?? .available(sentence: sentence, term: (sentence as NSString).range(of: word),
                                            cut: [], gap: nil)
        return try CapturedTerm.make(term: word, trigger: .selection, acquisition: .textRange, confidence: 1,
                                     source: SourceApp(bundleID: "com.example.reader"), pointer: nil, box: .absent,
                                     context: outcome)
    }

    /// Every description a log line, a `dump` or a hook could write of `value`.
    private func descriptions(of value: Any) -> [String] {
        [String(describing: value), String(reflecting: value)]
    }

    @Test func theSentenceNeverLeavesTheSession() async throws {
        let book = PendingContexts()
        let session = CaptureContextSession(pending: book)
        let requests = CaptureRequests()
        let consumer = Consumer()
        let endings = Mutex<[String]>([])
        requests.onEnd { ack in
            endings.withLock {
                $0 += [String(ack.request), String(ack.generation), ack.outcome.rawValue,
                       String(describing: ack), String(reflecting: ack)]
            }
        }

        // 1 — A delivery: the term goes to the consumer, the sentence only to the session.
        let first = try term()
        let one = requests.begin(.selection)
        let delivered = requests.deliver(first, for: one, to: consumer)
        #expect(delivered == .accepted)
        session.hold(first, request: one.number, generation: 1)

        var inspected = descriptions(of: first) + descriptions(of: first.context) + descriptions(of: session)
            + descriptions(of: one) + consumer.recorded + endings.withLock { $0 }
        let held = try #require(session.context(request: one.number, generation: 1), "the session lost its context")
        // The control: the marker is real and the session is the one holder — a scan that finds nothing has it to find.
        guard case .available(let heldSentence, _, _, _) = held else {
            Issue.record("the session did not hold the canary sentence, so a clean scan proves nothing")
            return
        }
        #expect(heldSentence.contains(Self.marker), "the session did not hold the canary sentence")
        inspected += descriptions(of: held)

        // 2 — A settlement: the reading answers with the sentence; the session takes it, the consumers see nothing.
        let reading = book.start(fallback: .unavailable(.notCaptured), bound: .seconds(30)) {
            .available(sentence: Self.sentence, term: (Self.sentence as NSString).range(of: Self.term), cut: [], gap: nil)
        }
        let waiting = try term(context: .pending(reading.handle))
        let two = requests.begin(.pointerGesture)
        _ = requests.deliver(waiting, for: two, to: consumer)
        session.hold(waiting, request: two.number, generation: 2)
        await reading.finished()
        await Task.yield()
        let settled = try #require(session.context(request: two.number, generation: 2))
        if case .available(let settledSentence, _, _, _) = settled {
            #expect(settledSentence.contains(Self.marker), "the settlement never reached the session")
        } else {
            Issue.record("the reading did not settle: \(settled)")
        }
        inspected += descriptions(of: settled) + descriptions(of: reading) + descriptions(of: reading.end as Any)
        #expect(requests.terminal(of: two) == nil, "a settlement acknowledged a request nobody drew")

        // 3 — A cancellation: the reading is dropped and the request ends cancelled.
        let cancelledReading = book.start(fallback: .unavailable(.notCaptured), bound: .seconds(30)) {
            try? await Task.sleep(for: .seconds(60))
            return nil
        }
        let dropping = try term(context: .pending(cancelledReading.handle))
        let three = requests.begin(.selection)
        _ = requests.deliver(dropping, for: three, to: consumer)
        session.hold(dropping, request: three.number, generation: 3)
        session.end(request: three.number)
        await cancelledReading.finished()
        inspected += descriptions(of: cancelledReading) + descriptions(of: cancelledReading.end as Any)
        #expect(session.isEmpty)

        // 4 — A replacement: another presentation replaces the held sentence, and closing drops it.
        let four = requests.begin(.service)
        _ = requests.deliver(try term(), for: four, to: consumer)
        session.hold(try term(), request: four.number, generation: 4)
        session.clear()
        inspected += descriptions(of: four)
        #expect(session.isEmpty)

        // 5 — The refusal path: a consumer that refuses ends the request cancelled.
        let refusing = Consumer(refused: true)
        let five = requests.begin(.menu)
        #expect(requests.deliver(try term(), for: five, to: refusing) == .refused)
        inspected += refusing.recorded + descriptions(of: five)
        #expect(requests.terminal(of: five)?.outcome == .cancelled)

        // The canary: no string a consumer could write names the sentence.
        let leaked = inspected.filter { $0.contains(Self.marker) }
        #expect(leaked.isEmpty, "the sentence escaped the session: \(leaked)")
    }
}

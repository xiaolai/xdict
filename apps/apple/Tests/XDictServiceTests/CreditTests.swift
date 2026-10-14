import Foundation
import Synchronization
import Testing
import XDictClient
import XDictContract
@testable import XDictService

/// **Credits bind one connection** (`Credits`): a connection past its class's credits is refused `tooManyInFlight`,
/// before anything reaches the core. The real `ServiceClient` never sends past its credits, so this asks as a defective
/// client would: three 63 MiB resources on one raw connection, at once.
@Suite(.serialized)
struct CreditTests {
    final class Replies: Sendable {
        let outcomes = Mutex<[UInt64: Result<Delivered, WireError>]>([:])
    }

    @Test func aThirdBulkCallOnOneConnectionIsRefused() async throws {
        let harness = try ServiceHarness()
        let fixtures = try ServiceHarness.fixtures()
        let slow = DictionaryPackage.of(mdx: fixtures.appending(path: "slow/slow.mdx"),
                                        volumes: [fixtures.appending(path: "slow/slow.mdd")])
        let dict = try await Self.ready(slow, on: harness.client())

        let connection = harness.connect(ConnectionEvents(interrupted: {}, invalidated: {}, event: { _ in }))
        defer { connection.invalidate() }
        let observer = FileObserver()
        let tokens = slow.files.map { observer.token($0) }
        let replies = Replies()
        let requests = (1...3).map { id in
            Request(id: UInt64(id), tokens: tokens, operation: .resource(dict: dict, path: "big.bin", render: .reader))
        }
        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                let envelope = try? request.encoded()
                group.addTask {
                    let exchange = await withCheckedContinuation { continuation in
                        connection.send(envelope ?? Data(), files: nil) { continuation.resume(returning: $0) }
                    }
                    let outcome: Result<Delivered, WireError> = switch exchange {
                    case .reply(let envelope, let payload): Response.read(envelope, payload: payload, answering: request)
                    case .failed(let why): .failure(why)
                    }
                    replies.outcomes.withLock { $0[request.id] = outcome }
                }
            }
        }
        let outcomes = replies.outcomes.withLock { $0 }
        let refused = outcomes.values.filter { $0 == .failure(.refused(.tooManyInFlight)) }.count
        let whole = outcomes.values.filter { outcome in
            guard case .success(let delivered) = outcome else { return false }
            return delivered.payload?.count == 63 << 20
        }.count
        #expect(outcomes.count == 3)
        #expect(refused == 1, "\(outcomes.mapValues { "\($0)".prefix(120) })")
        #expect(whole == 2)
    }

    /// Opened, importing first if the service asks for it.
    static func ready(_ package: DictionaryPackage, on client: ServiceClient) async throws -> DictId {
        if case .success(.ready(let dict, _, _)) = await client.open(package) { return dict }
        _ = try await client.importPackage(package).get()
        guard case .success(.ready(let dict, _, _)) = await client.open(package) else {
            throw CancellationError()
        }
        return dict
    }
}

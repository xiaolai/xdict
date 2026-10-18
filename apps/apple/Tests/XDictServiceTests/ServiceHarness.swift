import Foundation
import Synchronization
import Testing
import XDictClient
import XDictContract
@testable import XDictService

/// **The service, in this process**: its own listener delegate (`ServiceListener`) behind an anonymous NSXPC listener,
/// its core's storage in a directory of the test's own, an idle exit that never fires unless the test brings its own
/// (`IdleServiceTests`, with the test's clock and timer). Clients reach it over a real
/// NSXPC connection, through the real `ServiceClient`.
final class ServiceHarness: Sendable {
    let listener: Box
    let context: ServiceContext
    let storage: URL

    /// `NSXPCListener` is not `Sendable`; it is made once, here, and only invalidated. Its `delegate` is weak, so the
    /// box owns the service's listener delegate: nothing in `ServiceListener` points back here, so there is no cycle.
    final class Box: @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let service: ServiceListener

        init(service: ServiceListener) {
            self.service = service
            listener.delegate = service
            listener.resume()
        }
    }

    /// `appleImports`: the folder conversions use in place of the app-group container's (`AppleStaging`); none, as for
    /// a service without the entitlement, by default.
    init(check: ClientCheck = .anyoneForTests, idle: IdleExit? = nil, appleImports: AppleImportStore? = nil,
         conversionHeartbeat: Duration = .seconds(15)) throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "xdict-service-\(UUID().uuidString)")
        let idle = idle ?? IdleExit(quiet: .seconds(86_400), now: { ContinuousClock.now }, arm: { _ in }, exit: { _ in })
        context = ServiceContext(dictionaries: Dictionaries(storage: Dictionaries.Storage(
            indexes: storage.appending(path: "indexes"), registry: storage.appending(path: "registry"))), idle: idle,
            appleImports: appleImports, conversionHeartbeat: conversionHeartbeat)
        listener = Box(service: ServiceListener(context: context, check: check))
    }

    deinit {
        listener.listener.invalidate()
        try? FileManager.default.removeItem(at: storage)
    }

    /// Holds the harness: a client keeps the service it talks to alive, so a harness released after its last use (as
    /// ARC may, before an `await` on its client returns) does not invalidate the listener under the client.
    var connect: Connect {
        let endpoint = Endpoint(listener.listener.endpoint)
        return { [self] events in
            withExtendedLifetime(self) {
                XPCServiceConnection(NSXPCConnection(listenerEndpoint: endpoint.endpoint), events: events)
            }
        }
    }

    func client(_ options: ServiceClient.Options = .contract, watch: (@Sendable (ClientEvent) -> Void)? = nil) -> ServiceClient {
        ServiceClient(connect: connect, options: options, watch: watch)
    }

    /// `NSXPCListenerEndpoint` is not `Sendable`; it is only handed to `NSXPCConnection`.
    struct Endpoint: @unchecked Sendable {
        let endpoint: NSXPCListenerEndpoint
        init(_ endpoint: NSXPCListenerEndpoint) { self.endpoint = endpoint }
    }

    /// `Tools/build-fixtures.sh`'s output, which `make test` writes before `swift test` (and CI, before its run).
    static func fixtures() throws -> URL {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build/fixtures")
        try #require(FileManager.default.fileExists(atPath: fixtures.appending(path: "slow/heavy.mdx").path),
                     "no fixtures at \(fixtures.path): run `make test`, or Tools/build-fixtures.sh .build/fixtures")
        return fixtures
    }

    static func scratch() throws -> URL {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "xdict-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }
}

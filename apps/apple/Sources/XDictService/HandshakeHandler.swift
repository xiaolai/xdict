import Foundation
import XDictBase
import XDictCore
import os

/// The service's answer to the handshake: the versions of the core it links, read from the core itself.
final class HandshakeHandler: NSObject, HandshakeProtocol {
    private let log = Logger(subsystem: XDictIdentity.dictionaryService, category: "handshake")

    func versions(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        let versions = Self.wire(XDictCore.versions())
        do {
            reply(try JSONEncoder().encode(versions), nil)
            log.info("answered the handshake: core \(versions.core, privacy: .public), protocol \(versions.protocolVersion)")
        } catch {
            log.error("could not encode the core's versions: \(String(describing: error), privacy: .public)")
            reply(nil, "the core's versions could not be encoded: \(error)")
        }
    }

    /// The core's record as the wire value the app decodes.
    static func wire(_ versions: Versions) -> CoreVersions {
        CoreVersions(protocolVersion: versions.protocol, core: versions.core, indexFormat: versions.indexFormat,
                     normalization: versions.normalization)
    }
}

/// Accepts every connection launchd hands this service and exports the handshake on it. Who may connect is checked
/// from WI-3, with the contract (plan-macos-v1); today the one thing exported reveals four version numbers.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HandshakeProtocol.self)
        connection.exportedObject = HandshakeHandler()
        connection.resume()
        return true
    }
}

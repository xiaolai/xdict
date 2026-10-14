import SwiftUI
import XDictBase
import XDictUI
import os

/// The skeleton's app: one window, which asks the dictionary service for its core's versions as the app launches and
/// says what came back.
struct XDictApp: App {
    @State private var status = LaunchStatus.asking

    var body: some Scene {
        WindowGroup {
            LaunchView(status: status)
                .task { status = await Self.handshake() }
        }
        .windowResizability(.contentSize)
    }

    static func handshake() async -> LaunchStatus {
        let log = Logger(subsystem: XDictIdentity.app, category: "launch")
        switch await HandshakeClient.ask() {
        case .success(let versions):
            log.info("the dictionary service answered: core \(versions.core, privacy: .public), protocol \(versions.protocolVersion)")
            return .answered(versions)
        case .failure(let failure):
            log.error("the dictionary service did not answer: \(String(describing: failure), privacy: .public)")
            return .failed(failure)
        }
    }
}

import SwiftUI
import XDictBase
import XDictClient
import XDictEntryView
import XDictUI
import os

/// The skeleton's app: one window, which asks the dictionary service for its core's versions as the app launches and
/// says what came back — and whether entries can be shown confined on this Mac (ADR-0009 decision 7: the two WebKit
/// switches read back at launch; with either missing or still on, no entry will render, and the window says why).
struct XDictApp: App {
    /// The app's one client of its dictionary service: one connection at a time, made on demand (`ServiceClient`).
    static let service = ServiceClient()

    @State private var status = LaunchStatus.asking
    @State private var entries: LocalizedStringResource?

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 0) {
                LaunchView(status: status)
                    .task { status = await Self.handshake() }
                if let entries {
                    Text(entries).foregroundStyle(.secondary).padding([.horizontal, .bottom], 24)
                }
            }
            .task { entries = Self.entryReadiness() }
        }
        .windowResizability(.contentSize)
    }

    static func handshake() async -> LaunchStatus {
        let log = Logger(subsystem: XDictIdentity.app, category: "launch")
        switch await service.handshake() {
        case .success(let versions):
            log.info("the dictionary service answered: core \(versions.core, privacy: .public), protocol \(versions.protocolVersion)")
            return .answered(versions)
        case .failure(let failure):
            log.error("the dictionary service did not answer: \(String(describing: failure), privacy: .public)")
            return .failed(failure)
        }
    }

    @MainActor
    static func entryReadiness() -> LocalizedStringResource {
        switch EntryReadiness.check() {
        case .success: EntrySentences.ready
        case .failure(let why): EntrySentences.refusal(why)
        }
    }
}

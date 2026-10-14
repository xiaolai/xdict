import XDictBase
import XDictContract

extension ServiceClient {
    /// **What the app asks its service at launch**: the contract's `versions`, as the launch window and the
    /// `--handshake-report` instrument show it (the WI-2 handshake, replaced by the contract in WI-3). The versions travel
    /// under the core's own names (`CoreVersions`, which the E2E `launch` stage compares with the bundle's record).
    public func handshake() async -> Result<CoreVersions, HandshakeFailure> {
        switch await versions() {
        case .success(let versions):
            .success(CoreVersions(protocolVersion: versions.protocolVersion, core: versions.core,
                                  indexFormat: versions.indexFormat, normalization: versions.normalization))
        case .failure(let failure):
            .failure(Self.handshakeFailure(failure))
        }
    }

    /// Each way the call can fail, as one of the launch window's four sentences.
    nonisolated static func handshakeFailure(_ failure: ClientFailure) -> HandshakeFailure {
        switch failure {
        case .wire(.timedOut(let deadline)): .timedOut(after: deadline)
        case .wire(.interrupted), .wire(.invalidated): .unreachable(String(describing: failure))
        case .wire(.undecodable), .wire(.contractMismatch): .unreadable(String(describing: failure))
        case .wire(.core), .wire(.refused), .superseded, .fileUnavailable, .reopenNeedsImport, .needsFiles:
            .refused(String(describing: failure))
        }
    }
}

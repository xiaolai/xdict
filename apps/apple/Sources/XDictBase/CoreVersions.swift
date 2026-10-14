/// The core's versions as they cross from the service to the app: the protocol, the core's own version, the index
/// format and the normalisation (ADR-0007 decision 11), under the names the core's own record and
/// `Generated/core-versions.json` use. The app never links the core, so it holds them as this value, not the core's type.
public struct CoreVersions: Codable, Equatable, Hashable, Sendable {
    public let protocolVersion: UInt32
    public let core: String
    public let indexFormat: UInt32
    public let normalization: UInt32

    public init(protocolVersion: UInt32, core: String, indexFormat: UInt32, normalization: UInt32) {
        self.protocolVersion = protocolVersion
        self.core = core
        self.indexFormat = indexFormat
        self.normalization = normalization
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case core, indexFormat, normalization
    }
}

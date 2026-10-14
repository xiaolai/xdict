import Foundation
import XDictClient
import XDictContract

extension Projection {
    static func feature(_ f: Feature) -> [String: Any] {
        switch f {
        case .formatVersion(let version): ["type": "formatVersion", "version": version]
        case .resourceLibraryV3: ["type": "resourceLibraryV3"]
        case .registrationCode: ["type": "registrationCode"]
        case .encryptionFlags(let flags): ["type": "encryptionFlags", "flags": flags]
        case .lzoInV3: ["type": "lzoInV3"]
        case .compressionType(let code): ["type": "compressionType", "code": code]
        case .blockEncryption(let code): ["type": "blockEncryption", "code": code]
        case .encoding(let name): ["type": "encoding", "name": name]
        }
    }

    /// The core's error as its serde shape; `internalFault` is the core's `Internal`.
    static func core(_ e: CoreFailure) -> [String: Any] {
        switch e {
        case .unsupported(let f, let detail): ["type": "unsupported", "feature": feature(f), "detail": detail]
        case .malformed(let detail): ["type": "malformed", "detail": detail]
        case .tooLarge(let limit, let detail): ["type": "tooLarge", "limit": limit.rawValue, "detail": detail]
        case .notFound(let what, let detail): ["type": "notFound", "what": what.rawValue, "detail": detail]
        case .io(let kind, let detail): ["type": "io", "kind": kind.rawValue, "detail": detail]
        case .staleHandle(let detail): ["type": "staleHandle", "detail": detail]
        case .editionMismatch(let detail): ["type": "editionMismatch", "detail": detail]
        case .sourceChanged(let detail): ["type": "sourceChanged", "detail": detail]
        case .cancelled(let detail): ["type": "cancelled", "detail": detail]
        case .incompatible(let core, let client, let detail): ["type": "incompatible", "core": core, "client": client, "detail": detail]
        case .internalFault(let detail): ["type": "internal", "detail": detail]
        }
    }

    /// A failed call as the suites write one, `["error": …]`: the core's error in its shape, anything else named so it
    /// cannot match an expectation by accident.
    static func failure(_ f: ClientFailure) -> [String: Any] {
        if case .wire(.core(let error)) = f { return ["error": core(error)] }
        return ["error": ["type": "notACoreError", "detail": String(describing: f)]]
    }

    /// The outcome of a call: `project` of its answer, or its failure.
    static func outcome(_ outcome: ClientOutcome, _ project: (Delivered) -> Any) -> Any {
        switch outcome {
        case .success(let delivered): project(delivered)
        case .failure(let why): Self.failure(why)
        }
    }
}

// MARK: - The suites' comparison

/// **By subset** (`conformance/README.md`): every field written in the expectation must be present and equal; fields left
/// out are not compared; lists must have equal lengths; `comment` is never compared. The first difference, by path.
func subset(_ expected: Any, _ actual: Any, _ at: String) -> String? {
    if let e = expected as? [String: Any] {
        guard let a = actual as? [String: Any] else { return "\(at): expected an object, found \(actual)" }
        for (key, value) in e.sorted(by: { $0.key < $1.key }) where key != "comment" {
            guard let found = a[key] else { return "\(at).\(key): missing in \(a)" }
            if let failure = subset(value, found, "\(at).\(key)") { return failure }
        }
        return nil
    }
    if let e = expected as? [Any] {
        guard let a = actual as? [Any], a.count == e.count else { return "\(at): expected \(e), found \(actual)" }
        for (index, pair) in zip(e, a).enumerated() {
            if let failure = subset(pair.0, pair.1, "\(at)[\(index)]") { return failure }
        }
        return nil
    }
    if expected is NSNull { return actual is NSNull ? nil : "\(at): expected null, found \(actual)" }
    if let e = expected as? String, let a = actual as? String { return e == a ? nil : "\(at): expected \(e), found \(a)" }
    if let e = number(expected), let a = number(actual) { return e == a ? nil : "\(at): expected \(e), found \(a)" }
    return "\(at): expected \(expected), found \(actual)"
}

private func number(_ value: Any) -> NSNumber? {
    switch value {
    case let n as NSNumber where !(value is String): n
    case let n as UInt64: NSNumber(value: n)
    case let n as UInt32: NSNumber(value: n)
    case let n as UInt8: NSNumber(value: n)
    case let n as Int: NSNumber(value: n)
    case let n as Int64: NSNumber(value: n)
    default: nil
    }
}

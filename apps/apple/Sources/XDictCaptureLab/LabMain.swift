import ApplicationServices
import CoreGraphics
import Foundation
import XDictCaptureMac

/// How the lab's process ends.
enum LabStatus: Int32, Equatable {
    case success = 0
    /// Nothing was read, and standard error says why.
    case failure = 1
    /// A command the lab does not have (sysexits' `EX_USAGE`).
    case usage = 64
}

/// **The lab's process**: the report on standard output, one line; anything else on standard error, one line.
enum LabMain {
    @MainActor
    static func run(
        arguments: [String], source: @autoclosure () -> any PointerWordSource,
        out: (String) -> Void, err: (String) -> Void
    ) async -> LabStatus {
        switch LabCommand.parse(arguments) {
        case .failure(let usage):
            err(usage.message)
            return .usage
        case .success(.access):
            // The APIs that never prompt: `AXIsProcessTrusted` and `CGPreflightScreenCaptureAccess`.
            let report = ["accessibility": AXIsProcessTrusted(),
                          "screenRecording": CGPreflightScreenCaptureAccess()] as [String: Bool]
            guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else {
                err("the access report could not be written")
                return .failure
            }
            out(String(decoding: data, as: UTF8.self))
            return .success
        case .success(.readPoint(let point)):
            switch await ReadPoint.run(at: point, source: source()) {
            case .success(let report):
                do {
                    out(try report.jsonLine())
                    return .success
                } catch {
                    err("the report could not be written: \(error)")
                    return .failure
                }
            case .failure(let failure):
                err(failure.message)
                return .failure
            }
        }
    }
}

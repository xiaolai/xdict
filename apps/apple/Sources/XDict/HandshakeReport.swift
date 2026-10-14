import Foundation
import XDictBase

/// `XDict --handshake-report`: a development instrument, for the E2E `launch` stage (run on the E2E Mac only).
/// Asks the dictionary service embedded in this bundle for its core's versions, exactly as the app does at launch,
/// prints one JSON object and exits — 0 with `service` set, 1 with `failure` set. It opens no window and reads nothing
/// of the reader's, so it ships in every build (XiaolaiDict compiled out only instruments that read the screen or
/// another app, its ADR-0010).
///
/// `pid` and `parentPid` say how it was started: launched by LaunchServices (`open`), its parent is launchd, 1.
enum HandshakeReport {
    static let flag = "--handshake-report"

    struct Report: Encodable {
        let pid: Int32
        let parentPid: Int32
        let bundle: String
        let seconds: Double
        let service: CoreVersions?
        let failure: String?
    }

    static func run() -> Never {
        let started = ContinuousClock.now
        Task.detached {
            let outcome = await HandshakeClient.ask()
            let elapsed = (ContinuousClock.now - started).components
            var service: CoreVersions?, failure: String?
            switch outcome {
            case .success(let versions): service = versions
            case .failure(let why): failure = String(describing: why)
            }
            let report = Report(
                pid: ProcessInfo.processInfo.processIdentifier, parentPid: getppid(),
                bundle: Bundle.main.bundlePath,
                seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                service: service, failure: failure)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                FileHandle.standardOutput.write(try encoder.encode(report) + Data("\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("\(flag): the report could not be encoded: \(error)\n".utf8))
                exit(1)
            }
            exit(service == nil ? 1 : 0)
        }
        dispatchMain()
    }
}

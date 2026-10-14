import Foundation
import XDictBase
import XDictClient
import XDictEntryView

/// `XDict --handshake-report`: a development instrument, for the E2E `launch` stage (run on the E2E Mac only).
/// Asks the dictionary service embedded in this bundle for its core's versions through the contract (`versions`),
/// exactly as the app does at launch,
/// prints one JSON object and exits — 0 with `service` set, 1 with `failure` set. It opens no window and reads nothing
/// of the reader's, so it ships in every build (XiaolaiDict compiled out only instruments that read the screen or
/// another app, its ADR-0010).
///
/// `pid` and `parentPid` say how it was started: launched by LaunchServices (`open`), its parent is launchd, 1.
/// `entryView` is the entry view's launch check (ADR-0009 decision 7): the two WebKit switches turned off and read back
/// on a fresh `WKPreferences`, with no web view made — `ready`, each switch's read-back, or why it refuses.
enum HandshakeReport {
    static let flag = "--handshake-report"

    struct EntryViewCheck: Encodable {
        let ready: Bool
        let switches: [String: Bool]
        let refusal: String?
    }

    struct Report: Encodable {
        let pid: Int32
        let parentPid: Int32
        let bundle: String
        let seconds: Double
        let service: CoreVersions?
        let failure: String?
        let entryView: EntryViewCheck
    }

    static func run() -> Never {
        let started = ContinuousClock.now
        Task.detached {
            let outcome = await ServiceClient().handshake()
            let elapsed = (ContinuousClock.now - started).components
            var service: CoreVersions?, failure: String?
            switch outcome {
            case .success(let versions): service = versions
            case .failure(let why): failure = String(describing: why)
            }
            let entryView = await MainActor.run { () -> EntryViewCheck in
                switch EntryReadiness.check() {
                case .success(let switches): EntryViewCheck(ready: true, switches: switches, refusal: nil)
                case .failure(let why): EntryViewCheck(ready: false, switches: [:], refusal: String(describing: why))
                }
            }
            let report = Report(
                pid: ProcessInfo.processInfo.processIdentifier, parentPid: getppid(),
                bundle: Bundle.main.bundlePath,
                seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                service: service, failure: failure, entryView: entryView)
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
        // **The main thread's run loop, not `dispatchMain()`**: that parks the main thread, and the main queue is then
        // drained on another thread, where WebKit's initialisation (`WKPreferences()`, the entry view's check) stops
        // the process (EXC_BREAKPOINT in `WebKit::runInitializationCode`, measured on the E2E Mac 2026-10-14). A timer
        // keeps the run loop from returning for want of a source; the task above ends the process.
        RunLoop.main.add(Timer(timeInterval: 3600, repeats: true) { _ in }, forMode: .default)
        while true { RunLoop.main.run() }
    }
}

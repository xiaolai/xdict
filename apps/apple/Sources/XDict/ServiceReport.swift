import Foundation
import XDictClient
import XDictContract
import XDictInstruments

/// `XDict --service-report <fixtures> [--checks a,b,…]`: a development instrument, for the E2E `service` stage (run on
/// the E2E Mac only). Drives this bundle's own signed dictionary service through the app's `ServiceClient`, exactly as
/// the app does: `conformance/`'s fixtures through the contract, then the service's checks (plan-macos-v1 WI-3). Prints
/// one JSON object (`Findings`: every check with its detail, and the facts measured) and exits 0 when every check passed.
/// `<fixtures>` is `Tools/build-fixtures.sh`'s directory. Opens no window and reads only the fixtures it is pointed at.
///
/// Ends the service's process twice (the kill, and the idle exit) and takes about a minute, most of it the idle check's
/// quiet period; `--checks` names a subset, by the names in `checks`, for working on one.
enum ServiceReport {
    static let flag = "--service-report"
    static let checks = ["conformance", "refusals", "supersede", "drop", "stall", "kill", "idle"]

    static func run(_ arguments: [String]) -> Never {
        Task.detached {
            // **Held out of App Nap and timer coalescing for the whole run**: the idle check measures the service's quiet
            // period, and an instrument with no window, left to the system, woke 1.5 s late (2026-10-14).
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                 reason: "the service's checks measure its quiet period")
            let findings = await report(arguments)
            ProcessInfo.processInfo.endActivity(activity)
            do {
                FileHandle.standardOutput.write(try findings.json() + Data("\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("\(flag): the report could not be encoded: \(error)\n".utf8))
                exit(1)
            }
            exit(findings.passed ? 0 : 1)
        }
        dispatchMain()
    }

    static func report(_ arguments: [String]) async -> Findings {
        var findings = Findings()
        func value(after option: String) -> String? {
            arguments.firstIndex(of: option).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let fixtures = value(after: flag).map(URL.init(fileURLWithPath:)) else {
            findings.check("arguments", false, "usage: \(flag) <fixtures> [--checks \(checks.joined(separator: ","))]")
            return findings
        }
        let wanted = value(after: "--checks").map { $0.split(separator: ",").map(String.init) } ?? checks
        let unknown = Set(wanted).subtracting(checks)
        guard unknown.isEmpty else {
            findings.check("arguments", false, "no such checks: \(unknown.sorted()); the checks are \(checks)")
            return findings
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "xdict-service-report-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            findings.check("arguments", false, "no scratch directory: \(error)")
            return findings
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        findings.fact("pid", "\(getpid())")
        findings.fact("parentPid", "\(getppid())")
        findings.fact("bundle", Bundle.main.bundlePath)
        let service = ServiceChecks(fixtures: fixtures, scratch: scratch) { options, watch in
            ServiceClient(options: options, watch: watch)
        }
        for check in wanted {
            switch check {
            case "conformance":
                findings.merge(await ConformanceScenario(client: ServiceClient(), fixtures: fixtures, scratch: scratch).run())
            case "refusals": findings.merge(await service.refusals())
            case "supersede": findings.merge(await service.supersededReplyIsNeverDelivered())
            case "drop": findings.merge(await service.queuedSupersededIsNeverSent())
            case "stall": findings.merge(await service.stalledBulkFreesTheClient())
            case "kill": findings.merge(await service.killMidLookup())
            case "idle": findings.merge(await service.idleExitUnderLaunchd())
            default: break
            }
        }
        return findings
    }
}

/// `XDict --connect-report`: asks the dictionary service by its name, as the app does, and prints what came back —
/// `{"connected": true, …}` and exit 0, or the failure and exit 1. The E2E `service` stage runs it from inside the bundle
/// and from a copy of this executable outside it: **a program outside the bundle cannot reach the service by name**.
enum ConnectReport {
    static let flag = "--connect-report"

    struct Report: Encodable {
        let executable: String
        let connected: Bool
        let versions: Versions?
        let failure: String?
    }

    static func run() -> Never {
        Task.detached {
            let outcome = await ServiceClient().versions()
            var failure: String?, versions: Versions?
            if case .success(let answered) = outcome { versions = answered }
            if case .failure(let why) = outcome { failure = String(describing: why) }
            let report = Report(executable: CommandLine.arguments.first ?? "?", connected: failure == nil,
                                versions: versions, failure: failure)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(((try? encoder.encode(report)) ?? Data("{}".utf8)) + Data("\n".utf8))
            exit(failure == nil ? 0 : 1)
        }
        dispatchMain()
    }
}

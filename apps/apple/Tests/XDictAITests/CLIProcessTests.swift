import Foundation
import Synchronization
import Testing
@testable import XDictAI

/// **The child's pipes under stress** (ADR-0021 d.9; audit findings of 2026-10-20): a CLI that exits before reading its
/// prompt must not take XDict down with SIGPIPE, and a stream with no newline must not grow the pending line without
/// bound.
struct CLIProcessTests {
    static func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "xdict-cli-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func script(_ body: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: "child")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A child that exits at once, with a megabyte waiting on stdin: `write` meets a closed pipe. Without
    /// `F_SETNOSIGPIPE` this test process dies on SIGPIPE and never reports.
    @Test func aChildThatExitsBeforeReadingDoesNotSignalTheApp() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try Self.script("#!/bin/sh\nexit 0\n", in: directory)
        let run = try await CLIProcess.run(
            executable: executable, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: directory, input: String(repeating: "x", count: 1 << 20), deadline: .seconds(10))
        #expect(run.status == 0)
    }

    /// **Concurrency must not exhaust the process's descriptors** (2026-10-23): the readers were blocking work on the
    /// shared dispatch pool; under 32 concurrent runs the pool starved, the reader join timed out, and each abandoned
    /// join left two descriptors open until the 2,560-descriptor soft limit — where `posix_spawn` itself starts failing
    /// with EMFILE (`spawn(24)`). That is how the CLI provider tests went red under a loaded suite: clean at 4
    /// concurrent, EMFILE by the 43rd iteration at 32.
    @Test func manyConcurrentRunsKeepTheirDescriptors() async throws {
        let before = Self.openDescriptors()
        let failures = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    var failed = 0
                    for _ in 0..<100 {
                        do {
                            _ = try await CLIProcess.run(
                                executable: URL(filePath: "/bin/echo"), arguments: ["x"],
                                environment: ["PATH": "/usr/bin:/bin"], workingDirectory: URL(filePath: "/tmp"),
                                deadline: .seconds(10))
                        } catch {
                            failed += 1
                        }
                    }
                    return failed
                }
            }
            var total = 0
            for await failed in group { total += failed }
            return total
        }
        #expect(failures == 0, "\(failures) runs could not start")
        #expect(Self.openDescriptors() <= before + 8, "descriptors: \(before) → \(Self.openDescriptors())")
    }

    static func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// A megabyte with no newline: the pending line is dropped rather than held, and the run still ends.
    @Test func aNewlineFreeStreamDoesNotGrowThePendingLine() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = "#!/bin/sh\nhead -c 1048576 /dev/zero | tr '\\0' x\nexit 0\n"
        let executable = try Self.script(body, in: directory)
        let lines = Mutex(0)
        let run = try await CLIProcess.run(
            executable: executable, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: directory, input: nil, deadline: .seconds(20),
            onLine: { _ in lines.withLock { $0 += 1 } })
        #expect(run.status == 0)
        #expect(run.stdout.utf8.count <= CLIProcess.stdoutCap)
    }
}
